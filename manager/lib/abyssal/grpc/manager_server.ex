defmodule Abyssal.Grpc.ManagerServer do
  use GRPC.Server, service: Abyssal.V1.AbyssalManager.Service
  require Logger

  alias Abyssal.Crypto.KeyMaterial
  alias Abyssal.Datasets.{Publisher, ReleaseStore}

  def publish_dataset(request, _stream) do
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
          encrypted: false
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
          shamir_total: key_material.shamir_total || 0
        }

      {:error, reason} ->
        Logger.error("PublishDataset failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :internal, message: inspect(reason)
    end
  end

  defp publish_opts(%{encrypt: false}), do: [encrypt: false]

  defp publish_opts(%{encrypt: true} = request) do
    [encrypt: true, recovery: parse_recovery(request.recovery)]
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

  # 0 means "use Publisher's default" (see PublishDatasetRequest's proto
  # comment) -- don't override it with an explicit 0.
  defp maybe_put(opts, _key, 0), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  def read_range(request, _stream) do
    with {:ok, manifest} <- ReleaseStore.load_manifest(request.name, request.version),
         {:ok, key} <- resolve_key(manifest, request),
         {:ok, data, eof} <-
           Abyssal.EngineClient.read_range(
             manifest.archive_path,
             request.entry_path,
             request.offset,
             request.length,
             key
           ) do
      %Abyssal.V1.ReadRangeResponse{data: data, bytes_read: byte_size(data), eof: eof}
    else
      {:error, :enoent} ->
        raise GRPC.RPCError, status: :not_found, message: "dataset not found"

      {:error, :key_required} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "dataset is encrypted; supply raw_key_hex, recovery_phrase, or shares"

      # The engine's own decrypt-failure statuses (permission_denied,
      # data_loss, invalid_argument -- see engine/src/service.rs) pass
      # through unchanged rather than getting flattened to :internal.
      {:error, %GRPC.RPCError{} = error} ->
        raise error

      {:error, reason} ->
        Logger.error("ReadRange failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :internal, message: inspect(reason)
    end
  end

  # Key resolution happens here, before ever calling the engine -- an
  # encrypted dataset with no key material supplied at all is
  # unambiguously incomplete, no need to spend an RPC round trip on it.
  defp resolve_key(%{encrypted: false}, _request), do: {:ok, nil}

  defp resolve_key(%{encrypted: true}, request) do
    case key_material_from_request(request) do
      nil -> {:error, :key_required}
      key_material -> KeyMaterial.resolve(key_material)
    end
  end

  # ReadRangeRequest's raw_key_hex/recovery_phrase/shares are a proto3
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
