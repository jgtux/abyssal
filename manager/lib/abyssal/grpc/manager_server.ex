defmodule Abyssal.Grpc.ManagerServer do
  use GRPC.Server, service: Abyssal.V1.AbyssalManager.Service
  require Logger

  alias Abyssal.Datasets.{Publisher, ReleaseStore}

  def publish_dataset(request, _stream) do
    case Publisher.publish(request.name, request.version, request.source_dir) do
      {:ok, manifest} ->
        %Abyssal.V1.PublishDatasetResponse{
          archive_path: manifest.archive_path,
          archive_sha256: manifest.archive_sha256,
          entry_count: length(manifest.entries),
          created_at: DateTime.to_unix(manifest.created_at)
        }

      {:error, reason} ->
        Logger.error("PublishDataset failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :internal, message: inspect(reason)
    end
  end

  def read_range(request, _stream) do
    with {:ok, manifest} <- ReleaseStore.load_manifest(request.name, request.version),
         {:ok, data, eof} <-
           Abyssal.EngineClient.read_range(
             manifest.archive_path,
             request.entry_path,
             request.offset,
             request.length
           ) do
      %Abyssal.V1.ReadRangeResponse{data: data, bytes_read: byte_size(data), eof: eof}
    else
      {:error, :enoent} ->
        raise GRPC.RPCError, status: :not_found, message: "dataset not found"

      {:error, reason} ->
        Logger.error("ReadRange failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :internal, message: inspect(reason)
    end
  end
end
