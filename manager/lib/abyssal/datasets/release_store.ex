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

  def release_dir(name, version) do
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
