defmodule ZfsMonitor.StatsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "zfs_monitor.StatsRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:interval_seconds, 1, type: :int32, json_name: "intervalSeconds")
end

defmodule ZfsMonitor.IO do
  @moduledoc false

  use Protobuf, full_name: "zfs_monitor.IO", protoc_gen_elixir_version: "0.17.0", syntax: :proto3

  field(:read_ops, 1, type: :uint64, json_name: "readOps")
  field(:write_ops, 2, type: :uint64, json_name: "writeOps")
  field(:read_bytes, 3, type: :uint64, json_name: "readBytes")
  field(:write_bytes, 4, type: :uint64, json_name: "writeBytes")
end

defmodule ZfsMonitor.Pool do
  @moduledoc false

  use Protobuf,
    full_name: "zfs_monitor.Pool",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:name, 1, type: :string)
  field(:size_bytes, 2, type: :uint64, json_name: "sizeBytes")
  field(:allocated_bytes, 3, type: :uint64, json_name: "allocatedBytes")
  field(:free_bytes, 4, type: :uint64, json_name: "freeBytes")
  field(:capacity_percent, 5, type: :uint32, json_name: "capacityPercent")
  field(:health, 6, type: :string)
  field(:fragmentation, 7, type: :string)
  field(:io_stats, 8, type: ZfsMonitor.IO, json_name: "ioStats")
end

defmodule ZfsMonitor.ARC do
  @moduledoc false

  use Protobuf, full_name: "zfs_monitor.ARC", protoc_gen_elixir_version: "0.17.0", syntax: :proto3

  field(:size_bytes, 1, type: :uint64, json_name: "sizeBytes")
  field(:target_size_bytes, 2, type: :uint64, json_name: "targetSizeBytes")
  field(:max_size_bytes, 3, type: :uint64, json_name: "maxSizeBytes")
  field(:hit_rate_percent, 4, type: :double, json_name: "hitRatePercent")
  field(:miss_rate_percent, 5, type: :double, json_name: "missRatePercent")
  field(:hits, 6, type: :uint64)
  field(:misses, 7, type: :uint64)
end

defmodule ZfsMonitor.SystemInfo do
  @moduledoc false

  use Protobuf,
    full_name: "zfs_monitor.SystemInfo",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:hostname, 1, type: :string)
  field(:zfs_version, 2, type: :string, json_name: "zfsVersion")
  field(:uptime_seconds, 3, type: :uint64, json_name: "uptimeSeconds")
end

defmodule ZfsMonitor.StatsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "zfs_monitor.StatsResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:pools, 1, repeated: true, type: ZfsMonitor.Pool)
  field(:arc, 2, type: ZfsMonitor.ARC)
  field(:system, 3, type: ZfsMonitor.SystemInfo)
  field(:timestamp, 4, type: :int64)
  field(:collection_time_ms, 5, type: :int64, json_name: "collectionTimeMs")
end

defmodule ZfsMonitor.ZFSMonitor.Service do
  @moduledoc false

  use GRPC.Service, name: "zfs_monitor.ZFSMonitor", protoc_gen_elixir_version: "0.17.0"

  rpc(:GetStats, ZfsMonitor.StatsRequest, ZfsMonitor.StatsResponse)

  rpc(:StreamStats, ZfsMonitor.StatsRequest, stream(ZfsMonitor.StatsResponse))
end

defmodule ZfsMonitor.ZFSMonitor.Stub do
  @moduledoc false

  use GRPC.Stub, service: ZfsMonitor.ZFSMonitor.Service
end
