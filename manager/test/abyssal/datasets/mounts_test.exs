defmodule Abyssal.Datasets.MountsTest do
  @moduledoc """
  Real dwarfs FUSE mounts: needs mkdwarfs, dwarfs, fusermount3 and
  /dev/fuse. Run with: mix test --include requires_mkdwarfs --include requires_fuse
  """
  use ExUnit.Case, async: false

  import Abyssal.Test.IsolatedRoots

  alias Abyssal.Datasets.{Mounts, Publisher, ReleaseStore}

  @moduletag :requires_mkdwarfs
  @moduletag :requires_fuse

  setup :setup_isolated_roots

  @source Path.expand("../../../../testdata/hello", __DIR__)

  test "a plaintext publish is mounted straight away", %{mount_root: mount_root} do
    assert {:ok, _manifest} = Publisher.publish("hello", "v1", @source)
    assert File.read!(Path.join([mount_root, "hello", "v1", "hello.txt"])) == "hello world"
  end

  test "an encrypted publish is not mounted until key material is supplied",
       %{mount_root: mount_root, decrypt_root: decrypt_root} do
    assert {:ok, manifest, km} =
             Publisher.publish("hello", "v1", @source, encrypt: true, recovery: :phrase)

    refute File.exists?(Path.join([mount_root, "hello", "v1", "hello.txt"]))

    assert {:error, :key_required} = Mounts.ensure_mounted(manifest, nil)

    key = Base.decode16!(km.raw_key_hex, case: :lower)
    assert {:ok, mountpoint} = Mounts.ensure_mounted(manifest, key)
    assert File.read!(Path.join(mountpoint, "hello.txt")) == "hello world"

    decrypted = Path.join([decrypt_root, "hello", "v1.dwarfs"])
    assert File.stat!(decrypted).access == :read_write
    assert Bitwise.band(File.stat!(decrypted).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(decrypted)).mode, 0o777) == 0o700

    # Mounted, but the API still demands the right key every time.
    assert {:ok, ^mountpoint} = Mounts.ensure_mounted(manifest, key)

    assert {:error, :decrypt_failed} =
             Mounts.ensure_mounted(manifest, :crypto.strong_rand_bytes(32))

    assert {:error, :key_required} = Mounts.ensure_mounted(manifest, nil)

    assert :ok = Mounts.unmount("hello", "v1")
    refute File.exists?(decrypted)
    refute File.exists?(Path.join(mountpoint, "hello.txt"))
    assert {:error, :not_mounted} = Mounts.unmount("hello", "v1")
  end

  test "a wrong key never writes a decrypted image", %{decrypt_root: decrypt_root} do
    assert {:ok, manifest, _km} =
             Publisher.publish("hello", "v1", @source, encrypt: true, recovery: :phrase)

    assert {:error, :decrypt_failed} =
             Mounts.ensure_mounted(manifest, :crypto.strong_rand_bytes(32))

    refute File.exists?(Path.join([decrypt_root, "hello", "v1.dwarfs"]))
  end

  test "a corrupt encrypted archive is :corrupt_archive" do
    assert {:ok, manifest, km} =
             Publisher.publish("hello", "v1", @source, encrypt: true, recovery: :phrase)

    File.write!(ReleaseStore.archive_path("hello", "v1"), "ABY1short")
    key = Base.decode16!(km.raw_key_hex, case: :lower)
    assert {:error, :corrupt_archive} = Mounts.ensure_mounted(manifest, key)
  end

  test "restarting cleans up a stale mount left by a crashed run and re-mounts plaintext datasets",
       %{mount_root: mount_root} do
    assert {:ok, _manifest} = Publisher.publish("hello", "v1", @source)
    mountpoint = Path.join([mount_root, "hello", "v1"])

    # Simulate a crash: kill the owner without terminate/2 ever running,
    # so the FUSE mount survives it. The supervisor restarts Mounts, whose
    # init must unmount the orphan before mounting the dataset again.
    pid = Process.whereis(Mounts)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    wait_until(fn -> is_pid(Process.whereis(Mounts)) and Process.whereis(Mounts) != pid end)
    # handle_continue(:auto_mount) runs right after init; a sync call
    # queues behind it.
    :ok = :sys.get_state(Mounts) |> then(fn _ -> :ok end)

    assert File.read!(Path.join(mountpoint, "hello.txt")) == "hello world"

    stale_count =
      File.read!("/proc/self/mounts")
      |> String.split("\n")
      |> Enum.count(&String.contains?(&1, " #{mountpoint} fuse.dwarfs "))

    assert stale_count == 1
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end
end
