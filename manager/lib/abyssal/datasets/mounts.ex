defmodule Abyssal.Datasets.Mounts do
  @moduledoc """
  Owns every DwarFS FUSE mount the manager creates -- README's "Mounted
  mode" (`<mount_root>/<name>/<version>`). The single place mounts are
  created or destroyed; everything else asks for a mountpoint and reads
  from it directly (see `Abyssal.Datasets.Reader`), so reads never queue
  behind this process and run fully concurrently.

  Plaintext datasets are mounted eagerly (at boot and right after publish)
  and lazily on first read as a fallback.

  Encrypted datasets are only mounted when key material is supplied. The
  archive is one AES-GCM blob (see `Abyssal.Crypto.AesGcm`), and the dwarfs
  driver needs a real plaintext image file, so the decrypted image is
  written under `:decrypt_root` -- RAM-backed tmpfs by default
  (/dev/shm/abyssal), so plaintext never lands on persistent storage -- and
  stays there only while mounted. The key therefore gates *mounting*: once
  mounted, any local process allowed into the mountpoint can read it,
  which is the point of mounted mode. API reads still require the key on
  every call: an HMAC fingerprint of the key is kept (never the key
  itself) and checked in constant time against whatever a later caller
  supplies.

  Shutdown (`terminate/2`, so this traps exits) unmounts everything and
  wipes `:decrypt_root`. A hard crash can't run that, so `init/1` cleans up
  whatever a previous run left behind before mounting anything.
  """
  use GenServer
  require Logger

  alias Abyssal.Crypto.AesGcm
  alias Abyssal.Datasets.{Manifest, ReleaseStore}
  alias Abyssal.Dwarfs

  @fingerprint_context "abyssal-mount-check"

  # Decrypting + writing a large archive happens inside a call; the
  # default 5s timeout would kill perfectly healthy mounts of anything
  # beyond a few hundred MB.
  @call_timeout :timer.minutes(10)

  ## Client API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the mountpoint for `manifest`'s dataset, mounting it first if
  needed. `key` must be the raw 32-byte key for an encrypted dataset and
  is ignored for a plaintext one.
  """
  @spec ensure_mounted(Manifest.t(), binary() | nil) ::
          {:ok, Path.t()}
          | {:error, :key_required | :decrypt_failed | :corrupt_archive | term()}
  def ensure_mounted(%Manifest{} = manifest, key) do
    GenServer.call(__MODULE__, {:ensure_mounted, manifest, key}, @call_timeout)
  end

  @doc "Unmounts a dataset and deletes its decrypted image, if any."
  @spec unmount(String.t(), String.t()) :: :ok | {:error, :not_mounted | term()}
  def unmount(name, version), do: GenServer.call(__MODULE__, {:unmount, name, version})

  @doc "Unmounts everything this process mounted (shutdown, and test cleanup)."
  @spec unmount_all() :: :ok
  def unmount_all, do: GenServer.call(__MODULE__, :unmount_all, @call_timeout)

  @spec mount_root() :: Path.t()
  def mount_root, do: Application.get_env(:abyssal, :mount_root, "/mnt/abyssal") |> Path.expand()

  @spec decrypt_root() :: Path.t()
  def decrypt_root,
    do: Application.get_env(:abyssal, :decrypt_root, "/dev/shm/abyssal") |> Path.expand()

  ## Server

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    cleanup_stale_mounts()
    wipe_decrypt_root()
    {:ok, %{}, {:continue, :auto_mount}}
  end

  # After init returns, so a slow or failing mount of one dataset never
  # blocks (or crashes) the rest of the supervision tree from starting.
  @impl true
  def handle_continue(:auto_mount, state) do
    {:noreply, Enum.reduce(plaintext_manifests(), state, &auto_mount/2)}
  end

  @impl true
  def handle_call({:ensure_mounted, manifest, key}, _from, state) do
    id = {manifest.name, manifest.version}

    case do_ensure_mounted(Map.get(state, id), manifest, key) do
      {:ok, %{mountpoint: mountpoint} = entry} ->
        {:reply, {:ok, mountpoint}, Map.put(state, id, entry)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:unmount, name, version}, _from, state) do
    case Map.fetch(state, {name, version}) do
      {:ok, entry} ->
        case teardown(entry, lazy: false) do
          :ok -> {:reply, :ok, Map.delete(state, {name, version})}
          {:error, _} = error -> {:reply, error, state}
        end

      :error ->
        {:reply, {:error, :not_mounted}, state}
    end
  end

  def handle_call(:unmount_all, _from, state) do
    Enum.each(state, fn {_id, entry} -> teardown(entry, lazy: true) end)
    {:reply, :ok, %{}}
  end

  # trap_exit (needed for terminate/2) also delivers an :EXIT for every
  # System.cmd port Dwarfs opens once it closes -- expected, not an error.
  @impl true
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state, fn {_id, entry} -> teardown(entry, lazy: true) end)
    wipe_decrypt_root()
  end

  ## Mounting

  # Plaintext, already mounted.
  defp do_ensure_mounted(%{key_fingerprint: nil} = entry, _manifest, _key), do: {:ok, entry}

  # Encrypted, already mounted: the key must match the one it was mounted
  # with, or the API would serve plaintext to anyone once someone else
  # mounted it.
  defp do_ensure_mounted(%{} = _entry, _manifest, nil), do: {:error, :key_required}

  defp do_ensure_mounted(%{key_fingerprint: expected} = entry, _manifest, key) do
    if :crypto.hash_equals(expected, fingerprint(key)),
      do: {:ok, entry},
      else: {:error, :decrypt_failed}
  end

  defp do_ensure_mounted(nil, %Manifest{encrypted: false} = manifest, _key) do
    archive = ReleaseStore.archive_path(manifest.name, manifest.version)
    mountpoint = mountpoint(manifest)

    with :ok <- mount(archive, mountpoint) do
      {:ok, %{mountpoint: mountpoint, decrypted_path: nil, key_fingerprint: nil}}
    end
  end

  defp do_ensure_mounted(nil, %Manifest{encrypted: true}, nil), do: {:error, :key_required}

  defp do_ensure_mounted(nil, %Manifest{encrypted: true} = manifest, key) do
    archive = ReleaseStore.archive_path(manifest.name, manifest.version)
    mountpoint = mountpoint(manifest)
    decrypted_path = decrypted_path(manifest)

    with {:ok, data} <- File.read(archive),
         {:ok, nonce, ct} <- AesGcm.unwrap(data),
         {:ok, plaintext} <- AesGcm.decrypt(key, nonce, ct),
         :ok <- write_private(decrypted_path, plaintext),
         :ok <- mount_or_discard(decrypted_path, mountpoint) do
      {:ok,
       %{
         mountpoint: mountpoint,
         decrypted_path: decrypted_path,
         key_fingerprint: fingerprint(key)
       }}
    end
  end

  defp mount(image, mountpoint) do
    with :ok <- File.mkdir_p(mountpoint) do
      case Dwarfs.mount(image, mountpoint) do
        :ok ->
          :ok

        {:error, _} = error ->
          File.rmdir(mountpoint)
          error
      end
    end
  end

  defp mount_or_discard(decrypted_path, mountpoint) do
    with {:error, _} = error <- mount(decrypted_path, mountpoint) do
      File.rm(decrypted_path)
      error
    end
  end

  # The directory is 0700 before the file exists, and the file is created
  # empty and chmod'ed 0600 before any plaintext is written into it -- no
  # window where decrypted bytes sit in a file with umask-default perms.
  defp write_private(path, data) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(decrypt_root(), 0o700),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(path, ""),
         :ok <- File.chmod(path, 0o600) do
      File.write(path, data)
    end
  end

  defp teardown(%{mountpoint: mountpoint, decrypted_path: decrypted_path}, opts) do
    with :ok <- Dwarfs.unmount(mountpoint, opts) do
      File.rmdir(mountpoint)
      if decrypted_path, do: File.rm(decrypted_path)
      :ok
    end
  end

  defp auto_mount(manifest, state) do
    case do_ensure_mounted(nil, manifest, nil) do
      {:ok, entry} ->
        Map.put(state, {manifest.name, manifest.version}, entry)

      {:error, reason} ->
        Logger.warning(
          "auto-mount of #{manifest.name}@#{manifest.version} failed: #{inspect(reason)}"
        )

        state
    end
  end

  defp plaintext_manifests do
    ReleaseStore.root()
    |> Path.join("*/*/manifest.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      with {:ok, json} <- File.read(path),
           {:ok, %Manifest{encrypted: false} = manifest} <- Manifest.from_json(json) do
        [manifest]
      else
        _ -> []
      end
    end)
  end

  ## Cleanup

  # Anything under mount_root still mounted by the dwarfs driver at boot
  # was left by a previous run that died without terminate/2 (kill -9,
  # VM crash). Nothing in this run's state knows about it, so it would
  # otherwise make every later mount of that dataset fail.
  defp cleanup_stale_mounts do
    root = mount_root()

    case File.read("/proc/self/mounts") do
      {:ok, mounts} ->
        for line <- String.split(mounts, "\n", trim: true),
            [_source, target, "fuse.dwarfs" | _] <- [String.split(line, " ")],
            target = unescape_mount_field(target),
            String.starts_with?(target, root <> "/") do
          Logger.warning("unmounting stale dwarfs mount #{target}")
          Dwarfs.unmount(target, lazy: true)
        end

        :ok

      {:error, _} ->
        :ok
    end
  end

  # /proc/self/mounts octal-escapes space, tab, newline and backslash.
  defp unescape_mount_field(field) do
    Regex.replace(~r/\\([0-7]{3})/, field, fn _, octal ->
      <<String.to_integer(octal, 8)>>
    end)
  end

  defp wipe_decrypt_root, do: File.rm_rf(decrypt_root())

  ## Paths

  defp mountpoint(%Manifest{name: name, version: version}) do
    # ReleaseStore.release_dir/2 already raises on an unsafe segment, and
    # every manifest here was loaded through it -- re-checked anyway since
    # this path is also created on disk.
    true = ReleaseStore.valid_segment?(name) and ReleaseStore.valid_segment?(version)
    Path.join([mount_root(), name, version])
  end

  defp decrypted_path(%Manifest{name: name, version: version}),
    do: Path.join([decrypt_root(), name, version <> ".dwarfs"])

  defp fingerprint(key), do: :crypto.mac(:hmac, :sha256, key, @fingerprint_context)
end
