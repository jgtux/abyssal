defmodule Abyssal.Grpc.ManagerServer do
  use GRPC.Server, service: Abyssal.V1.AbyssalManager.Service
  require Logger

  alias Abyssal.Crypto.KeyMaterial
  alias Abyssal.Datasets.{Mounts, Publisher, Reader, ReleaseStore}

  def publish_dataset(request, _stream) do
    case validate_name_version(request.name, request.version) do
      :ok -> do_publish_dataset(request)
      {:error, message} -> raise GRPC.RPCError, status: :invalid_argument, message: message
    end
  end

  defp do_publish_dataset(request) do
    case Publisher.publish(
           request.name,
           request.version,
           request.source_dir,
           publish_opts(request)
         ) do
      {:ok, manifest} ->
        %Abyssal.V1.PublishDatasetResponse{
          archive_path: manifest.archive_path,
          archive_sha256: manifest.archive_sha256,
          entry_count: length(manifest.entries),
          created_at: DateTime.to_unix(manifest.created_at),
          encrypted: false,
          compression_profile: manifest.compression_profile
        }

      {:ok, manifest, key_material} ->
        %Abyssal.V1.PublishDatasetResponse{
          archive_path: manifest.archive_path,
          archive_sha256: manifest.archive_sha256,
          entry_count: length(manifest.entries),
          created_at: DateTime.to_unix(manifest.created_at),
          encrypted: true,
          raw_key_hex: key_material.raw_key_hex,
          recovery_phrase: key_material.recovery_phrase || "",
          shares: key_material.shares || [],
          shamir_threshold: key_material.shamir_threshold || 0,
          shamir_total: key_material.shamir_total || 0,
          compression_profile: manifest.compression_profile
        }

      {:error, reason} ->
        Logger.error("PublishDataset failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :internal, message: inspect(reason)
    end
  end

  defp publish_opts(%{encrypt: false} = request) do
    [encrypt: false] ++ compression_profile_opt(request)
  end

  defp publish_opts(%{encrypt: true} = request) do
    ([encrypt: true, recovery: parse_recovery(request.recovery)] ++
       compression_profile_opt(request))
    |> maybe_put(:shamir_threshold, request.shamir_threshold)
    |> maybe_put(:shamir_shares, request.shamir_shares)
  end

  defp parse_recovery("phrase"), do: :phrase
  defp parse_recovery("split"), do: :split
  defp parse_recovery("both"), do: :both
  # Anything else (including "") is passed through as-is so
  # Publisher.publish/4's own validation rejects it with a clear
  # {:invalid_recovery, _} error rather than silently picking a default.
  defp parse_recovery(other), do: other

  # "" means "not supplied" -- omit the opt entirely so Publisher's own
  # default (:balanced) applies, same "absence means default" idiom as
  # maybe_put/3 below uses for the Shamir integers.
  defp compression_profile_opt(%{compression_profile: ""}), do: []

  defp compression_profile_opt(%{compression_profile: profile}),
    do: [compression_profile: parse_compression_profile(profile)]

  defp parse_compression_profile("hot"), do: :hot
  defp parse_compression_profile("balanced"), do: :balanced
  defp parse_compression_profile("archive"), do: :archive
  # Anything else passed through as-is so Publisher.publish/4's own
  # validation rejects it with a clear {:invalid_compression_profile, _}
  # error rather than silently picking a default.
  defp parse_compression_profile(other), do: other

  # 0 means "use Publisher's default" (see PublishDatasetRequest's proto
  # comment) -- don't override it with an explicit 0.
  defp maybe_put(opts, _key, 0), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  def read_range(request, _stream) do
    with :ok <- validate_name_version(request.name, request.version),
         {:ok, manifest} <- ReleaseStore.load_manifest(request.name, request.version),
         {:ok, key} <- resolve_key(manifest, request),
         {:ok, mountpoint} <- Mounts.ensure_mounted(manifest, key),
         {:ok, data, eof} <-
           Reader.read_range(mountpoint, request.entry_path, request.offset, request.length) do
      %Abyssal.V1.ReadRangeResponse{data: data, bytes_read: byte_size(data), eof: eof}
    else
      error -> raise_rpc_error("ReadRange", error)
    end
  end

  def mount_dataset(request, _stream) do
    with :ok <- validate_name_version(request.name, request.version),
         {:ok, manifest} <- ReleaseStore.load_manifest(request.name, request.version),
         {:ok, key} <- resolve_key(manifest, request),
         {:ok, mountpoint} <- Mounts.ensure_mounted(manifest, key) do
      %Abyssal.V1.MountDatasetResponse{mountpoint: mountpoint, encrypted: manifest.encrypted}
    else
      error -> raise_rpc_error("MountDataset", error)
    end
  end

  def unmount_dataset(request, _stream) do
    with :ok <- validate_name_version(request.name, request.version),
         :ok <- Mounts.unmount(request.name, request.version) do
      %Abyssal.V1.UnmountDatasetResponse{}
    else
      error -> raise_rpc_error("UnmountDataset", error)
    end
  end

  # One mapping for every dataset-access RPC, so a given failure means the
  # same status everywhere. DecryptFailed is deliberately its own status
  # (permission_denied): "wrong key" is a meaningfully different operator
  # message than "you forgot to supply one", and AES-GCM can't tell a wrong
  # key from a tampered archive, so the message doesn't over-claim either.
  # CorruptArchive means the file can't even hold a valid header.
  defp raise_rpc_error(rpc, error) do
    {status, message} =
      case error do
        {:error, message} when is_binary(message) ->
          {:invalid_argument, message}

        {:error, :key_required} ->
          {:invalid_argument,
           "dataset is encrypted; supply raw_key_hex, recovery_phrase, or shares"}

        {:error, reason} when reason in [:invalid_key, :invalid_key_length, :invalid_hex] ->
          {:invalid_argument, "key must be exactly 32 bytes of hex"}

        # Malformed recovery material (Mnemonic.decode/1, Shamir.combine/1)
        # is the caller's input, not a server fault.
        {:error, reason}
        when reason in [
               :invalid_word_count,
               :unknown_word,
               :bad_checksum,
               :too_few_shares,
               :duplicate_share_index
             ] ->
          {:invalid_argument, "invalid key material: #{reason}"}

        {:error, {:corrupt_share, idx}} ->
          {:invalid_argument, "invalid key material: share #{idx} is corrupt"}

        {:error, :invalid_entry_path} ->
          {:invalid_argument, "entry_path must be a relative path inside the dataset"}

        {:error, :length_too_large} ->
          {:invalid_argument,
           "length exceeds the maximum of #{Reader.max_read_length()} bytes per read"}

        {:error, :decrypt_failed} ->
          {:permission_denied, "decryption failed: wrong key or corrupted archive"}

        {:error, :corrupt_archive} ->
          {:data_loss, "encrypted archive header is malformed"}

        {:error, :enoent} ->
          {:not_found, "dataset or entry not found"}

        {:error, :eisdir} ->
          {:invalid_argument, "entry_path is a directory"}

        {:error, :not_mounted} ->
          {:failed_precondition, "dataset is not mounted"}

        other ->
          Logger.error("#{rpc} failed: #{inspect(other)}")
          {:internal, inspect(other)}
      end

    raise GRPC.RPCError, status: status, message: message
  end

  # name/version become filesystem path segments (ReleaseStore.release_dir/2)
  # with zero other validation between the wire and disk -- reject a bad
  # one here, at the trust boundary, for a clean invalid_argument instead
  # of letting the ArgumentError ReleaseStore itself raises as a last
  # resort surface as an opaque :internal error. Both are unauthenticated
  # gRPC-facing fields, so this is real attack surface, not paranoia:
  # confirmed a name/version containing ".." resolves outside release_root
  # once the OS actually opens/creates the path, i.e. arbitrary file
  # write via PublishDataset without this check.
  defp validate_name_version(name, version) do
    if ReleaseStore.valid_segment?(name) and ReleaseStore.valid_segment?(version) do
      :ok
    else
      {:error, "invalid dataset name or version"}
    end
  end

  # An encrypted dataset with no key material supplied at all is
  # unambiguously incomplete -- rejected before touching Mounts.
  defp resolve_key(%{encrypted: false}, _request), do: {:ok, nil}

  defp resolve_key(%{encrypted: true}, request) do
    case key_material_from_request(request) do
      nil -> {:error, :key_required}
      key_material -> KeyMaterial.resolve(key_material)
    end
  end

  # ReadRangeRequest's and MountDatasetRequest's raw_key_hex/recovery_phrase/shares are a proto3
  # `oneof`, which the protobuf lib collapses into a single struct field
  # (key_material) holding a tagged tuple -- not three separate flat
  # fields as the .proto source's field list might suggest at a glance
  # (confirmed empirically: %Abyssal.V1.ReadRangeRequest{} only has a
  # key_material field, no raw_key_hex/recovery_phrase/shares fields of
  # their own).
  defp key_material_from_request(%{key_material: {:raw_key_hex, hex}})
       when hex not in [nil, ""],
       do: {:raw_key_hex, hex}

  defp key_material_from_request(%{key_material: {:recovery_phrase, phrase}})
       when phrase not in [nil, ""],
       do: {:recovery_phrase, phrase}

  defp key_material_from_request(%{key_material: {:shares, %Abyssal.V1.KeyShares{share: shares}}})
       when shares not in [nil, []],
       do: {:shares, shares}

  defp key_material_from_request(_request), do: nil
end
