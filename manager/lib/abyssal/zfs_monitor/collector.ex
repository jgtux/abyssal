defmodule Abyssal.ZfsMonitor.Collector do
  require Logger

  def collect_all_stats do
    start_time = System.monotonic_time(:millisecond)

    tasks = [
      Task.async(fn -> {:pools, collect_pools()} end),
      Task.async(fn -> {:arc, collect_arc()} end),
      Task.async(fn -> {:system, collect_system_info()} end)
    ]

    results =
      tasks
      |> Task.await_many(10_000)
      |> Enum.into(%{})

    collection_time = System.monotonic_time(:millisecond) - start_time

    stats = %{
      pools: results[:pools] || [],
      arc: results[:arc] || %{},
      system: results[:system] || %{},
      timestamp: DateTime.utc_now() |> DateTime.to_unix(),
      collection_time_ms: collection_time
    }

    Logger.debug("Stats collected in #{collection_time}ms")
    {:ok, stats}
  rescue
    e ->
      Logger.error("Failed to collect stats: #{inspect(e)}")
      {:error, e}
  end

  defp collect_pools do
    case System.cmd("zpool", ["list", "-Hp", "-o", "name,size,alloc,free,cap,frag,health"]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_pool_line/1)
        |> Enum.reject(&is_nil/1)

      {error, code} ->
        Logger.error("zpool list failed (#{code}): #{error}")
        []
    end
  end

  defp parse_pool_line(line) do
    case String.split(line, "\t") do
      [name, size, alloc, free, cap, frag, health] ->
        %{
          name: name,
          size_bytes: parse_int(size),
          allocated_bytes: parse_int(alloc),
          free_bytes: parse_int(free),
          capacity_percent: parse_int(cap),
          fragmentation: frag,
          health: health,
          io_stats: %{read_ops: 0, write_ops: 0, read_bytes: 0, write_bytes: 0}
        }

      _ ->
        nil
    end
  end

  defp collect_arc do
    %{
      size_bytes: 0,
      target_size_bytes: 0,
      max_size_bytes: 0,
      hit_rate_percent: 0.0,
      miss_rate_percent: 0.0,
      hits: 0,
      misses: 0
    }
  end

  defp collect_system_info do
    %{
      hostname: get_hostname(),
      zfs_version: "N/A",
      uptime_seconds: 0
    }
  end

  defp get_hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      _ -> "unknown"
    end
  end

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> 0
    end
  end

  defp parse_int(_), do: 0
end
