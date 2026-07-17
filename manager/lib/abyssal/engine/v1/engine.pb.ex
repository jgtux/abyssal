defmodule Abyssal.Engine.V1.EngineReadRangeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "abyssal.engine.v1.EngineReadRangeRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:archive_path, 1, type: :string, json_name: "archivePath")
  field(:entry_path, 2, type: :string, json_name: "entryPath")
  field(:offset, 3, type: :uint64)
  field(:length, 4, type: :uint64)
end

defmodule Abyssal.Engine.V1.EngineReadRangeResponse do
  @moduledoc false

  use Protobuf,
    full_name: "abyssal.engine.v1.EngineReadRangeResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:data, 1, type: :bytes)
  field(:bytes_read, 2, type: :uint64, json_name: "bytesRead")
  field(:eof, 3, type: :bool)
end

defmodule Abyssal.Engine.V1.DwarfsEngine.Service do
  @moduledoc false

  use GRPC.Service, name: "abyssal.engine.v1.DwarfsEngine", protoc_gen_elixir_version: "0.17.0"

  rpc(
    :ReadRange,
    Abyssal.Engine.V1.EngineReadRangeRequest,
    Abyssal.Engine.V1.EngineReadRangeResponse
  )
end

defmodule Abyssal.Engine.V1.DwarfsEngine.Stub do
  @moduledoc false

  use GRPC.Stub, service: Abyssal.Engine.V1.DwarfsEngine.Service
end
