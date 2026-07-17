defmodule Abyssal.EngineClientTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Exercises Abyssal.EngineClient against a real running abyssal-engine
  binary. Requires the Rust engine to already be built and running (see
  engine/scripts/build-libdwarfs.sh and `cargo run` under engine/), and a
  fixture archive built with mkdwarfs -- both explicit prerequisites, so
  this is excluded from the default `mix test` run (see test_helper.exs).

  Run with: ABYSSAL_ENGINE_ADDR=127.0.0.1:50052 mix test --include requires_engine
  """

  @tag :requires_engine
  @tag :requires_mkdwarfs
  test "read_range returns real bytes from a real archive via the Rust engine" do
    source = Path.join(__DIR__, "../../../testdata/hello") |> Path.expand()
    tmp = Path.join(System.tmp_dir!(), "abyssal_engine_client_test")
    File.mkdir_p!(tmp)
    archive_path = Path.join(tmp, "hello.dwarfs")

    {_output, 0} = System.cmd("mkdwarfs", ["-i", source, "-o", archive_path])

    assert {:ok, data, true} = Abyssal.EngineClient.read_range(archive_path, "hello.txt", 0, 11)
    assert data == "hello world"

    File.rm_rf!(tmp)
  end
end
