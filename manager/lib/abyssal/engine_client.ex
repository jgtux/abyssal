defmodule Abyssal.EngineClient do
  @moduledoc """
  Thin GRPC.Stub wrapper around the DwarfsEngine.ReadRange RPC (the Rust
  engine defined in engine/proto/abyssal/engine/v1/engine.proto).
  Reconnects per call for now -- simplest thing that works for the
  skeleton; worth promoting to a held connection (e.g. a small GenServer
  wrapping a persistent GRPC.Stub channel) once this is more than a demo
  path.
  """
  require Logger

  @spec read_range(
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          binary() | nil
        ) :: {:ok, binary(), boolean()} | {:error, term()}
  def read_range(archive_path, entry_path, offset, length, key \\ nil) do
    addr = engine_addr()

    with {:ok, channel} <- GRPC.Stub.connect(addr) do
      request = %Abyssal.Engine.V1.EngineReadRangeRequest{
        archive_path: archive_path,
        entry_path: entry_path,
        offset: offset,
        length: length,
        key: key || <<>>
      }

      result =
        case Abyssal.Engine.V1.DwarfsEngine.Stub.read_range(channel, request) do
          {:ok, %Abyssal.Engine.V1.EngineReadRangeResponse{data: data, eof: eof}} ->
            {:ok, data, eof}

          {:error, reason} ->
            Logger.error("engine ReadRange failed: #{inspect(reason)}")
            {:error, reason}
        end

      GRPC.Stub.disconnect(channel)
      result
    end
  end

  defp engine_addr do
    Application.get_env(:abyssal, :engine_addr, "127.0.0.1:50052")
  end
end
