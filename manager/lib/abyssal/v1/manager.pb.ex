defmodule Abyssal.V1.PublishDatasetRequest do
  @moduledoc false

  use Protobuf,
    full_name: "abyssal.v1.PublishDatasetRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:name, 1, type: :string)
  field(:version, 2, type: :string)
  field(:source_dir, 3, type: :string, json_name: "sourceDir")
end

defmodule Abyssal.V1.PublishDatasetResponse do
  @moduledoc false

  use Protobuf,
    full_name: "abyssal.v1.PublishDatasetResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:archive_path, 1, type: :string, json_name: "archivePath")
  field(:archive_sha256, 2, type: :string, json_name: "archiveSha256")
  field(:entry_count, 3, type: :uint32, json_name: "entryCount")
  field(:created_at, 4, type: :int64, json_name: "createdAt")
end

defmodule Abyssal.V1.ReadRangeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "abyssal.v1.ReadRangeRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:name, 1, type: :string)
  field(:version, 2, type: :string)
  field(:entry_path, 3, type: :string, json_name: "entryPath")
  field(:offset, 4, type: :uint64)
  field(:length, 5, type: :uint64)
end

defmodule Abyssal.V1.ReadRangeResponse do
  @moduledoc false

  use Protobuf,
    full_name: "abyssal.v1.ReadRangeResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:data, 1, type: :bytes)
  field(:bytes_read, 2, type: :uint64, json_name: "bytesRead")
  field(:eof, 3, type: :bool)
end

defmodule Abyssal.V1.AbyssalManager.Service do
  @moduledoc false

  use GRPC.Service, name: "abyssal.v1.AbyssalManager", protoc_gen_elixir_version: "0.17.0"

  rpc(:PublishDataset, Abyssal.V1.PublishDatasetRequest, Abyssal.V1.PublishDatasetResponse)

  rpc(:ReadRange, Abyssal.V1.ReadRangeRequest, Abyssal.V1.ReadRangeResponse)
end

defmodule Abyssal.V1.AbyssalManager.Stub do
  @moduledoc false

  use GRPC.Stub, service: Abyssal.V1.AbyssalManager.Service
end
