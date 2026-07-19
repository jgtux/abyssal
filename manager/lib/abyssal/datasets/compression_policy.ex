defmodule Abyssal.Datasets.CompressionPolicy do
  @moduledoc """
  Implements README.md's Dynamic Compression Behavior policy: as ZFS pool
  capacity rises, new publishes that don't explicitly request a profile
  get a stronger one automatically. Existing artifacts are never touched.

  README describes two thresholds (70% -> "stronger compression", 85% ->
  "archive profile"), but only three named profiles exist (:hot,
  :balanced, :archive), and :hot is a read-latency optimization unrelated
  to disk pressure -- never auto-selected here. Since :archive is already
  the strongest option, both README thresholds collapse to the same
  outcome; there's no fourth tier to invent. This module implements a
  single threshold at the more conservative of the two (70%) -- a
  deliberate reading, not an oversight.

  Worst-case wins across multiple pools; unavailable stats (nil, or an
  empty pools list -- see Collector.collect_pools/0) fall back to
  :balanced.
  """

  alias Abyssal.ZfsMonitor.Cache

  @archive_threshold_percent 70

  @type profile :: :balanced | :archive

  @spec resolve_dynamic_profile() :: profile()
  def resolve_dynamic_profile, do: resolve_dynamic_profile(Cache.get_stats())

  @spec resolve_dynamic_profile(nil | %{optional(:pools) => [map()]}) :: profile()
  def resolve_dynamic_profile(nil), do: :balanced

  def resolve_dynamic_profile(%{pools: pools}) do
    case worst_case_capacity_percent(pools) do
      nil -> :balanced
      pct when pct >= @archive_threshold_percent -> :archive
      _pct -> :balanced
    end
  end

  defp worst_case_capacity_percent([]), do: nil

  defp worst_case_capacity_percent(pools),
    do: pools |> Enum.map(& &1.capacity_percent) |> Enum.max()
end
