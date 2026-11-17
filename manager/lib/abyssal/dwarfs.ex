defmodule Abyssal.Dwarfs do
  @moduledoc """
  Thin `System.cmd` wrappers around the `dwarfs` FUSE driver and
  `fusermount3` -- the same shell-out pattern `Abyssal.Datasets.Publisher`
  uses for `mkdwarfs` and `Abyssal.ZfsMonitor.Collector` uses for `zpool`.
  The CLIs are upstream's stable, versioned interface; there is no native
  binding to keep in sync.

  Binaries are configurable (`:dwarfs_bin` / `:fusermount_bin`, see
  config/config.exs) so a pinned release tarball can be used without
  touching PATH.
  """
  require Logger

  @doc """
  Mounts `image` at `mountpoint`. `dwarfs` daemonizes and only returns once
  the mount is live, so the mountpoint is readable as soon as this returns
  `:ok`. DwarFS images are read-only by construction.
  """
  @spec mount(Path.t(), Path.t()) :: :ok | {:error, term()}
  def mount(image, mountpoint) do
    run(:dwarfs_bin, "dwarfs", [image, mountpoint], :mount_failed)
  end

  @doc """
  Unmounts `mountpoint`. `lazy: true` (`-z`) detaches even while busy --
  used on shutdown and stale-mount cleanup, where refusing would just
  leave the mount behind for good.
  """
  @spec unmount(Path.t(), keyword()) :: :ok | {:error, term()}
  def unmount(mountpoint, opts \\ []) do
    flags = if Keyword.get(opts, :lazy, false), do: ["-u", "-z"], else: ["-u"]
    run(:fusermount_bin, "fusermount3", flags ++ [mountpoint], :unmount_failed)
  end

  # Same :enoent guard as Collector's zpool call (see that commit): a
  # missing binary makes System.cmd raise rather than return, which would
  # crash the calling GenServer instead of surfacing a clear error.
  defp run(config_key, default_bin, args, failure_tag) do
    bin = Application.get_env(:abyssal, config_key, default_bin)

    case System.cmd(bin, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, code} ->
        Logger.error("#{bin} #{Enum.join(args, " ")} failed (#{code}): #{output}")
        {:error, {failure_tag, code, String.trim(output)}}
    end
  rescue
    e in ErlangError ->
      case e.original do
        :enoent -> {:error, {:binary_not_found, bin_name(config_key, default_bin)}}
        _ -> reraise e, __STACKTRACE__
      end
  end

  defp bin_name(config_key, default_bin),
    do: Application.get_env(:abyssal, config_key, default_bin)
end
