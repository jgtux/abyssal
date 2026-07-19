defmodule Abyssal.Datasets.CompressionPolicyTest do
  use ExUnit.Case, async: true

  alias Abyssal.Datasets.CompressionPolicy

  test "nil stats fall back to :balanced" do
    assert CompressionPolicy.resolve_dynamic_profile(nil) == :balanced
  end

  test "empty pools list falls back to :balanced" do
    assert CompressionPolicy.resolve_dynamic_profile(%{pools: []}) == :balanced
  end

  test "single pool below threshold resolves to :balanced" do
    stats = %{pools: [%{capacity_percent: 69}]}
    assert CompressionPolicy.resolve_dynamic_profile(stats) == :balanced
  end

  test "single pool at threshold resolves to :archive" do
    stats = %{pools: [%{capacity_percent: 70}]}
    assert CompressionPolicy.resolve_dynamic_profile(stats) == :archive
  end

  test "single pool above threshold resolves to :archive" do
    stats = %{pools: [%{capacity_percent: 91}]}
    assert CompressionPolicy.resolve_dynamic_profile(stats) == :archive
  end

  test "multiple pools: worst case (max) wins, a low pool doesn't mask a high one" do
    stats = %{pools: [%{capacity_percent: 12}, %{capacity_percent: 88}]}
    assert CompressionPolicy.resolve_dynamic_profile(stats) == :archive

    stats2 = %{pools: [%{capacity_percent: 40}, %{capacity_percent: 55}]}
    assert CompressionPolicy.resolve_dynamic_profile(stats2) == :balanced
  end
end
