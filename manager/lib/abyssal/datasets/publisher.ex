defmodule Abyssal.Datasets.Publisher do
  @moduledoc """
  Builds a `.dwarfs` artifact by shelling out to `mkdwarfs`, the same
  System.cmd shell-out pattern already used by
  `Abyssal.ZfsMonitor.Collector` for `zpool list`. Deliberate, not a
  shortcut: upstream dwarfs itself says the writer APIs are likely to
  change pre-1.0, while `mkdwarfs` the CLI is the stable, versioned
  interface -- see the discussion in the plan's Context section.

  Optionally encrypts the built archive at rest (see `publish/4`).
  """
  require Logger

  alias Abyssal.Crypto.{AesGcm, Mnemonic, Shamir}
  alias Abyssal.Datasets.{Manifest, ReleaseStore}

  @default_shamir_threshold 3
  @default_shamir_shares 5

  @default_compression_profile :balanced
  @compression_profiles [:hot, :balanced, :archive]

  @type key_material :: %{
          raw_key_hex: String.t(),
          recovery_phrase: String.t() | nil,
          shares: [String.t()] | nil,
          shamir_threshold: pos_integer() | nil,
          shamir_total: pos_integer() | nil
        }

  @doc """
  Publishes `source_dir` as `name`/`version`.

  With no opts, behaves exactly as before: builds the plaintext archive,
  returns `{:ok, manifest}`.

  Pass `encrypt: true, recovery: :phrase | :split | :both` (plus optional
  `shamir_threshold:`/`shamir_shares:`, defaulting to #{@default_shamir_threshold}-of-#{@default_shamir_shares})
  to encrypt the archive at rest with a freshly generated per-dataset key.
  Returns the extra `key_material` element in that case -- the manager
  never persists keys (see `Abyssal.Crypto.KeyMaterial`'s moduledoc), so
  this return value is the *only* place that key material is ever
  surfaced.

  Pass `compression_profile: :hot | :balanced | :archive` (default
  `#{inspect(@default_compression_profile)}`) to control the `mkdwarfs -l`
  level used to build the archive -- see README.md's Compression Profiles
  section.
  """
  @spec publish(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Manifest.t()} | {:ok, Manifest.t(), key_material()} | {:error, term()}
  def publish(name, version, source_dir, opts \\ []) do
    encrypt? = Keyword.get(opts, :encrypt, false)

    with :ok <- ensure_source_dir(source_dir),
         :ok <- validate_encrypt_opts(encrypt?, opts),
         {:ok, compression_profile} <- resolve_compression_profile(opts) do
      ReleaseStore.ensure_release_dir!(name, version)
      archive_path = ReleaseStore.archive_path(name, version)

      case run_mkdwarfs(source_dir, archive_path, compression_profile) do
        :ok ->
          finish_publish(
            name,
            version,
            source_dir,
            archive_path,
            compression_profile,
            encrypt?,
            opts
          )

        {:error, _} = error ->
          error
      end
    end
  end

  defp validate_encrypt_opts(false, _opts), do: :ok

  defp validate_encrypt_opts(true, opts) do
    case Keyword.get(opts, :recovery) do
      r when r in [:phrase, :split, :both] -> :ok
      other -> {:error, {:invalid_recovery, other}}
    end
  end

  defp resolve_compression_profile(opts) do
    case Keyword.get(opts, :compression_profile, @default_compression_profile) do
      profile when profile in @compression_profiles -> {:ok, profile}
      other -> {:error, {:invalid_compression_profile, other}}
    end
  end

  defp finish_publish(name, version, source_dir, archive_path, compression_profile, false, _opts) do
    manifest = build_manifest(name, version, source_dir, archive_path, compression_profile, %{})
    write_manifest!(name, version, manifest)
    {:ok, manifest}
  end

  defp finish_publish(name, version, source_dir, archive_path, compression_profile, true, opts) do
    {crypto_fields, key_material} = encrypt_archive!(archive_path, opts)

    manifest =
      build_manifest(name, version, source_dir, archive_path, compression_profile, crypto_fields)

    write_manifest!(name, version, manifest)
    {:ok, manifest, key_material}
  end

  defp write_manifest!(name, version, manifest) do
    File.write!(ReleaseStore.manifest_path(name, version), Manifest.to_json(manifest))
  end

  # Encrypts the archive already written to `archive_path` (by
  # run_mkdwarfs) in place, overwriting the plaintext with
  # magic <> nonce <> ciphertext <> tag (see Abyssal.Crypto.AesGcm.wrap/2).
  # Whole-file, not streaming: AES-GCM needs the entire message to produce
  # one tag, and the engine's mount_root_memfs call takes one pointer+
  # length upfront anyway -- acceptable at this project's current scale,
  # same class of simplification as the engine's own whole-mmap mount.
  defp encrypt_archive!(archive_path, opts) do
    plaintext = File.read!(archive_path)
    key = AesGcm.generate_key()
    {nonce, ciphertext_with_tag} = AesGcm.encrypt(plaintext, key)
    File.write!(archive_path, AesGcm.wrap(nonce, ciphertext_with_tag))

    crypto_fields = %{
      encrypted: true,
      cipher: "aes-256-gcm",
      nonce: Base.encode16(nonce, case: :lower)
    }

    {crypto_fields, build_key_material(key, opts)}
  end

  defp build_key_material(key, opts) do
    recovery = Keyword.fetch!(opts, :recovery)
    threshold = Keyword.get(opts, :shamir_threshold, @default_shamir_threshold)
    total = Keyword.get(opts, :shamir_shares, @default_shamir_shares)

    phrase =
      if recovery in [:phrase, :both] do
        {:ok, phrase} = Mnemonic.encode(key)
        phrase
      end

    shares =
      if recovery in [:split, :both] do
        {:ok, shares} = Shamir.split(key, threshold, total)
        shares
      end

    %{
      raw_key_hex: Base.encode16(key, case: :lower),
      recovery_phrase: phrase,
      shares: shares,
      shamir_threshold: if(shares, do: threshold),
      shamir_total: if(shares, do: total)
    }
  end

  defp ensure_source_dir(source_dir) do
    if File.dir?(source_dir) do
      :ok
    else
      {:error, {:source_dir_not_found, source_dir}}
    end
  end

  # -l N is mkdwarfs's single "sensible defaults bundle" flag (block size +
  # compression algorithm + window size + inode order together, see
  # `mkdwarfs --long-help`'s compression-level table) -- deliberately not
  # using `--compression`/category flags: -l alone gives three real,
  # verified-distinct behaviors that line up with README's Hot/Balanced/
  # Archive text, without depending on version-fragile category syntax.
  # zstd:level=11 -- README's "zstd low"
  defp mkdwarfs_level(:hot), do: "4"
  # zstd:level=22 -- mkdwarfs's own default
  defp mkdwarfs_level(:balanced), do: "7"
  # lzma:level=9 -- README's "lzma... rarely accessed"
  defp mkdwarfs_level(:archive), do: "9"

  defp run_mkdwarfs(source_dir, archive_path, compression_profile) do
    case System.cmd(
           "mkdwarfs",
           [
             "-i",
             source_dir,
             "-o",
             archive_path,
             "-l",
             mkdwarfs_level(compression_profile),
             "--progress",
             "none"
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, code} ->
        Logger.error("mkdwarfs failed (#{code}): #{output}")
        {:error, {:mkdwarfs_failed, code, output}}
    end
  end

  # crypto_fields is %{} for a plaintext publish, or %{encrypted:, cipher:,
  # nonce:} for an encrypted one. sha256_file runs against whatever is
  # physically on disk at archive_path at this point -- plaintext, or
  # ciphertext when encrypt_archive!/2 has already overwritten it -- so
  # archive_sha256 keeps its existing meaning ("hash of the file that
  # crosses the OS-process boundary to the engine") in both cases, and
  # additionally proves the encrypted-at-rest file wasn't corrupted
  # without needing the key.
  defp build_manifest(name, version, source_dir, archive_path, compression_profile, crypto_fields) do
    entries =
      source_dir
      |> list_files()
      |> Enum.map(fn path ->
        relative = Path.relative_to(path, source_dir)
        %{path: relative, size: File.stat!(path).size}
      end)

    Map.merge(
      %Manifest{
        name: name,
        version: version,
        created_at: DateTime.utc_now(),
        archive_path: archive_path,
        archive_sha256: sha256_file(archive_path),
        entries: entries,
        compression_profile: Atom.to_string(compression_profile)
      },
      crypto_fields
    )
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
