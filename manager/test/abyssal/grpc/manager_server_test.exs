defmodule Abyssal.Grpc.ManagerServerTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Exercises ManagerServer.read_range/2 directly -- GRPC.Server callbacks
  are plain functions for a unary RPC that never touches `stream`, so no
  actual bound gRPC listener is needed -- against a real running
  abyssal-engine binary and a real Publisher-encrypted dataset. This is
  the highest-risk seam in the whole feature: it proves the Elixir-
  written encrypted-archive format is actually readable by the Rust
  decryptor, not just that each side is self-consistent with its own
  unit tests.

  Run with: ABYSSAL_ENGINE_ADDR=127.0.0.1:50052 mix test --include requires_engine --include requires_mkdwarfs
  """

  alias Abyssal.Datasets.Publisher
  alias Abyssal.Grpc.ManagerServer

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "abyssal_manager_server_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    Application.put_env(:abyssal, :release_root, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:abyssal, :release_root)
    end)

    :ok
  end

  @tag :requires_engine
  @tag :requires_mkdwarfs
  test "read_range on an encrypted dataset with no key material is invalid_argument" do
    source = Path.join(__DIR__, "../../../../testdata/hello") |> Path.expand()

    assert {:ok, _manifest, _key_material} =
             Publisher.publish("hello", "v1", source, encrypt: true, recovery: :both)

    request = %Abyssal.V1.ReadRangeRequest{
      name: "hello",
      version: "v1",
      entry_path: "hello.txt",
      offset: 0,
      length: 11
    }

    error = assert_raise(GRPC.RPCError, fn -> ManagerServer.read_range(request, nil) end)
    assert error.status == GRPC.Status.invalid_argument()
    assert error.message =~ "supply raw_key_hex, recovery_phrase, or shares"
  end

  @tag :requires_engine
  @tag :requires_mkdwarfs
  test "read_range on an encrypted dataset with a wrong key propagates the engine's permission_denied" do
    source = Path.join(__DIR__, "../../../../testdata/hello") |> Path.expand()

    assert {:ok, _manifest, _key_material} =
             Publisher.publish("hello", "v1", source, encrypt: true, recovery: :both)

    wrong_key_hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    request = %Abyssal.V1.ReadRangeRequest{
      name: "hello",
      version: "v1",
      entry_path: "hello.txt",
      offset: 0,
      length: 11,
      key_material: {:raw_key_hex, wrong_key_hex}
    }

    error = assert_raise(GRPC.RPCError, fn -> ManagerServer.read_range(request, nil) end)
    assert error.status == GRPC.Status.permission_denied()
  end

  @tag :requires_engine
  @tag :requires_mkdwarfs
  test "read_range on an encrypted dataset: raw key, phrase, and shares all independently decrypt correctly" do
    source = Path.join(__DIR__, "../../../../testdata/hello") |> Path.expand()
    expected = File.read!(Path.join(source, "hello.txt"))

    assert {:ok, _manifest, key_material} =
             Publisher.publish("hello", "v1", source,
               encrypt: true,
               recovery: :both,
               shamir_threshold: 3,
               shamir_shares: 5
             )

    base_request = %Abyssal.V1.ReadRangeRequest{
      name: "hello",
      version: "v1",
      entry_path: "hello.txt",
      offset: 0,
      length: 11
    }

    forms = %{
      "raw key" => {:raw_key_hex, key_material.raw_key_hex},
      "phrase" => {:recovery_phrase, key_material.recovery_phrase},
      "shares" => {:shares, %Abyssal.V1.KeyShares{share: Enum.take(key_material.shares, 3)}}
    }

    for {label, key_material_field} <- forms do
      response = ManagerServer.read_range(%{base_request | key_material: key_material_field}, nil)

      assert response.data == expected,
             "#{label}: expected #{inspect(expected)}, got #{inspect(response.data)}"

      assert response.eof == true
    end
  end
end
