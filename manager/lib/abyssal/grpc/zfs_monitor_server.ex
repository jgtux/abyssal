defmodule Abyssal.Grpc.ZfsMonitorServer do
  use GRPC.Server, service: ZfsMonitor.ZFSMonitor.Service
  require Logger

  def get_stats(_request, _stream) do
    stats =
      case Abyssal.ZfsMonitor.Cache.get_stats() do
        nil ->
          case Abyssal.ZfsMonitor.Collector.collect_all_stats() do
            {:ok, s} -> s
            {:error, _} -> raise GRPC.RPCError, status: :internal
          end

        s ->
          s
      end

    build_response(stats)
  end

  def stream_stats(request, stream) do
    interval = max(request.interval_seconds * 1000, 1_000)
    Logger.info("Client started streaming (interval: #{interval}ms)")
    stream_loop(stream, interval)
  end

  def get_pool_details(_request, _stream) do
    {:error, GRPC.RPCError.exception(status: :unimplemented)}
  end

  defp stream_loop(stream, interval) do
    case Abyssal.ZfsMonitor.Cache.get_stats() do
      nil -> :ok
      stats -> GRPC.Server.send_reply(stream, build_response(stats))
    end

    Process.sleep(interval)
    stream_loop(stream, interval)
  end

  defp build_response(stats) do
    %ZfsMonitor.StatsResponse{
      pools: Enum.map(stats.pools, &build_pool/1),
      arc: build_arc(stats.arc),
      system: build_system(stats.system),
      timestamp: stats.timestamp,
      collection_time_ms: stats.collection_time_ms
    }
  end

  defp build_pool(pool) do
    %ZfsMonitor.Pool{
      name: pool.name,
      size_bytes: pool.size_bytes,
      allocated_bytes: pool.allocated_bytes,
      free_bytes: pool.free_bytes,
      capacity_percent: pool.capacity_percent,
      health: pool.health,
      fragmentation: pool.fragmentation,
      io_stats: %ZfsMonitor.IO{
        read_ops: pool.io_stats.read_ops,
        write_ops: pool.io_stats.write_ops,
        read_bytes: pool.io_stats.read_bytes,
        write_bytes: pool.io_stats.write_bytes
      }
    }
  end

  defp build_arc(arc) do
    %ZfsMonitor.ARC{
      size_bytes: arc.size_bytes,
      target_size_bytes: arc.target_size_bytes,
      max_size_bytes: arc.max_size_bytes,
      hit_rate_percent: arc.hit_rate_percent,
      miss_rate_percent: arc.miss_rate_percent,
      hits: arc.hits,
      misses: arc.misses
    }
  end

  defp build_system(system) do
    %ZfsMonitor.SystemInfo{
      hostname: system.hostname,
      zfs_version: system.zfs_version,
      uptime_seconds: system.uptime_seconds
    }
  end
end
