defmodule Abyssal.Datasets.Reader do
  @moduledoc """
  Range reads over a mounted dataset's directory tree. Pure file I/O --
  knows nothing about DwarFS, FUSE, or encryption; `Abyssal.Datasets.Mounts`
  hands it a mountpoint and it preads from there. That also makes it
  testable against a plain temp directory with no FUSE at all.
  """

  # `length` comes straight from an unauthenticated gRPC request with no
  # other bound on it, and `:file.pread/3` allocates a buffer of that size
  # up front. A single request with e.g. length = 2^64-1 would try to
  # allocate it and take down the whole VM with it. 64 MiB is a generous
  # cap for a range-read API -- large enough for any real chunked-read
  # use, small enough to never risk an allocation failure in the first
  # place. (Carried over from the old Rust engine, where the same request
  # aborted the process via handle_alloc_error.)
  @max_read_length 64 * 1024 * 1024

  @spec max_read_length() :: pos_integer()
  def max_read_length, do: @max_read_length

  @doc """
  Reads up to `length` bytes of `entry_path` (relative to `root_dir`)
  starting at `offset`. `eof` is true when the read reached the end of
  the entry.
  """
  @spec read_range(Path.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary(), boolean()}
          | {:error, :length_too_large | :invalid_entry_path | File.posix()}
  def read_range(_root_dir, _entry_path, _offset, length) when length > @max_read_length,
    do: {:error, :length_too_large}

  def read_range(root_dir, entry_path, offset, length) do
    with {:ok, path} <- resolve(root_dir, entry_path),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path) do
      pread(path, offset, length, size)
    else
      {:ok, %File.Stat{}} -> {:error, :eisdir}
      {:error, _} = error -> error
    end
  end

  # entry_path used to resolve inside libdwarfs' in-process memfs; it now
  # resolves on the real filesystem under a mountpoint, so "../" or an
  # absolute path would read arbitrary host files -- real attack surface
  # from an unauthenticated gRPC field. Path.safe_relative/2 rejects
  # anything that escapes root_dir, including via symlinks inside it.
  defp resolve(root_dir, entry_path) do
    case Path.safe_relative(String.trim_leading(entry_path, "/"), root_dir) do
      {:ok, ""} -> {:error, :invalid_entry_path}
      {:ok, relative} -> {:ok, Path.join(root_dir, relative)}
      :error -> {:error, :invalid_entry_path}
    end
  end

  defp pread(path, offset, length, size) do
    with {:ok, fd} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        case :file.pread(fd, offset, length) do
          {:ok, data} -> {:ok, data, offset + byte_size(data) >= size}
          :eof -> {:ok, <<>>, true}
          {:error, _} = error -> error
        end
      after
        :file.close(fd)
      end
    end
  end
end
