defmodule Abyssal.Datasets.Publisher do
  @moduledoc """
  Builds a `.dwarfs` artifact by shelling out to `mkdwarfs`, the same
  System.cmd shell-out pattern already used by
  `Abyssal.ZfsMonitor.Collector` for `zpool list`. Deliberate, not a
  shortcut: upstream dwarfs itself says the writer APIs are likely to
  change pre-1.0, while `mkdwarfs` the CLI is the stable, versioned
  interface -- see the discussion in the plan's Context section.
  """
  require Logger

  alias Abyssal.Datasets.{Manifest, ReleaseStore}

  @spec publish(String.t(), String.t(), String.t()) ::
          {:ok, Manifest.t()} | {:error, term()}
  def publish(name, version, source_dir) do
    with :ok <- ensure_source_dir(source_dir) do
      ReleaseStore.ensure_release_dir!(name, version)
      archive_path = ReleaseStore.archive_path(name, version)

      case run_mkdwarfs(source_dir, archive_path) do
        :ok ->
          manifest = build_manifest(name, version, source_dir, archive_path)
          File.write!(ReleaseStore.manifest_path(name, version), Manifest.to_json(manifest))
          {:ok, manifest}

        {:error, _} = error ->
          error
      end
    end
  end

  defp ensure_source_dir(source_dir) do
    if File.dir?(source_dir) do
      :ok
    else
      {:error, {:source_dir_not_found, source_dir}}
    end
  end

  defp run_mkdwarfs(source_dir, archive_path) do
    case System.cmd("mkdwarfs", ["-i", source_dir, "-o", archive_path, "--progress", "none"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, code} ->
        Logger.error("mkdwarfs failed (#{code}): #{output}")
        {:error, {:mkdwarfs_failed, code, output}}
    end
  end

  defp build_manifest(name, version, source_dir, archive_path) do
    entries =
      source_dir
      |> list_files()
      |> Enum.map(fn path ->
        relative = Path.relative_to(path, source_dir)
        %{path: relative, size: File.stat!(path).size}
      end)

    %Manifest{
      name: name,
      version: version,
      created_at: DateTime.utc_now(),
      archive_path: archive_path,
      archive_sha256: sha256_file(archive_path),
      entries: entries
    }
  end

  defp list_files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
  end

  defp sha256_file(path) do
    path
    |> File.stream!([], 2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
