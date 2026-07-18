defmodule Abyssal.Datasets.ReleaseStore do
  @moduledoc """
  Resolves name/version to on-disk paths under a configurable root.

  This directory is the explicit stand-in for the README's future "ZFS
  releases dataset" -- for this skeleton milestone it's just a plain
  directory (no ZFS pool, no mounting). When real ZFS integration lands,
  this is the seam: `root/<name>/<version>/` becomes a ZFS dataset instead
  of a plain directory, and callers of this module shouldn't need to
  change.
  """

  @default_root "data/releases"

  # Always absolute: archive_path/2 is sent as-is to the engine, a
  # separate OS process with its own working directory, so a relative
  # root would resolve against the wrong directory there.
  def root do
    Application.get_env(:abyssal, :release_root, @default_root)
    |> Path.expand()
  end

  @doc """
  True iff `segment` is safe to use as a single path component under
  `root()`. Rejects anything that could escape the release root once the
  OS resolves the path (empty, ".." anywhere, or a path separator) --
  `Path.join`/`Path.expand` do NOT collapse ".." themselves, but every
  actual filesystem call downstream (File.mkdir_p!, File.write!, the
  archive_path handed to the Rust engine) resolves it via the kernel,
  so an unvalidated name/version is a real path-traversal primitive, not
  just a theoretical one. `name`/`version` reach here straight from the
  gRPC request with no other validation, so this is the enforcement
  point -- called from `release_dir/2` so every path built through this
  module is covered, not just the ones the manager's gRPC handlers
  happen to check.
  """
  @spec valid_segment?(String.t()) :: boolean()
  def valid_segment?(segment) do
    is_binary(segment) and segment != "" and
      not String.contains?(segment, ["/", "\\", ".."])
  end

  def release_dir(name, version) do
    unless valid_segment?(name) and valid_segment?(version) do
      raise ArgumentError,
            "invalid dataset name/version: #{inspect(name)}/#{inspect(version)}"
    end

    Path.join([root(), name, version])
  end

  def archive_path(name, version) do
    Path.join(release_dir(name, version), "archive.dwarfs")
  end

  def manifest_path(name, version) do
    Path.join(release_dir(name, version), "manifest.json")
  end

  def ensure_release_dir!(name, version) do
    dir = release_dir(name, version)
    File.mkdir_p!(dir)
    dir
  end

  @spec load_manifest(String.t(), String.t()) ::
          {:ok, Abyssal.Datasets.Manifest.t()} | {:error, term()}
  def load_manifest(name, version) do
    path = manifest_path(name, version)

    with {:ok, json} <- File.read(path) do
      Abyssal.Datasets.Manifest.from_json(json)
    end
  end
end
