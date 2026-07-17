defmodule Abyssal.ZfsMonitor.Cache do
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 5_000)
    send(self(), :collect)

    state = %{
      stats: nil,
      interval: interval,
      collection_count: 0
    }

    Logger.info("Stats cache started with #{interval}ms interval")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_info(:collect, state) do
    case Abyssal.ZfsMonitor.Collector.collect_all_stats() do
      {:ok, stats} ->
        Logger.debug("Stats collected (##{state.collection_count + 1})")
        Process.send_after(self(), :collect, state.interval)

        {:noreply, %{state | stats: stats, collection_count: state.collection_count + 1}}

      {:error, reason} ->
        Logger.error("Collection failed: #{inspect(reason)}")
        Process.send_after(self(), :collect, state.interval)
        {:noreply, state}
    end
  end
end
