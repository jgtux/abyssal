defmodule Abyssal.Grpc.ManagerServerTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Exercises ManagerServer's handlers directly -- GRPC.Server callbacks are
  plain functions for a unary RPC that never touches `stream`, so no
  actual bound gRPC listener is needed -- against real Publisher-built
  datasets and real dwarfs FUSE mounts.

  Run with: mix test --include requires_mkdwarfs --include requires_fuse
  """

  import Abyssal.Test.IsolatedRoots

  alias Abyssal.Datasets.Publisher
  alias Abyssal.Grpc.ManagerServer
  alias Abyssal.V1.{MountDatasetRequest, ReadRangeRequest, UnmountDatasetRequest}

  @moduletag :requires_mkdwarfs
  @moduletag :requires_fuse

  @source Path.expand("../../../../testdata/hello", __DIR__)

  setup :setup_isolated_roots

  defp read_request(overrides \\ []) do
    struct!(
      %ReadRangeRequest{
        name: "hello",
        version: "v1",
        entry_path: "hello.txt",
        offset: 0,
        length: 11
      },
      overrides
    )
  end

  defp publish_encrypted! do
    assert {:ok, _manifest, key_material} =
             Publisher.publish("hello", "v1", @source,
               encrypt: true,
               recovery: :both,
               shamir_threshold: 3,
               shamir_shares: 5
             )

    key_material
  end

  defp rpc_error(fun), do: assert_raise(GRPC.RPCError, fun)

  test "read_range on a plaintext dataset" do
    assert {:ok, _manifest} = Publisher.publish("hello", "v1", @source)

    response = ManagerServer.read_range(read_request(offset: 6, length: 5), nil)
    assert response.data == "world"
    assert response.bytes_read == 5
    assert response.eof
  end

  test "read_range on an encrypted dataset with no key material is invalid_argument" do
    publish_encrypted!()

    error = rpc_error(fn -> ManagerServer.read_range(read_request(), nil) end)
    assert error.status == GRPC.Status.invalid_argument()
    assert error.message =~ "supply raw_key_hex, recovery_phrase, or shares"
  end

  test "read_range on an encrypted dataset with a wrong key is permission_denied" do
    publish_encrypted!()
    wrong_key_hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    error =
      rpc_error(fn ->
        ManagerServer.read_range(read_request(key_material: {:raw_key_hex, wrong_key_hex}), nil)
      end)

    assert error.status == GRPC.Status.permission_denied()
  end

  test "read_range on an encrypted dataset: raw key, phrase, and shares all independently decrypt correctly" do
    key_material = publish_encrypted!()
    expected = File.read!(Path.join(@source, "hello.txt"))

    forms = %{
      "raw key" => {:raw_key_hex, key_material.raw_key_hex},
      "phrase" => {:recovery_phrase, key_material.recovery_phrase},
      "shares" => {:shares, %Abyssal.V1.KeyShares{share: Enum.take(key_material.shares, 3)}}
    }

    for {label, key_material_field} <- forms do
      response = ManagerServer.read_range(read_request(key_material: key_material_field), nil)

      assert response.data == expected,
             "#{label}: expected #{inspect(expected)}, got #{inspect(response.data)}"

      assert response.eof == true
    end
  end

  test "a wrong key on an already-mounted encrypted dataset is still permission_denied" do
    key_material = publish_encrypted!()

    mounted =
      ManagerServer.mount_dataset(
        %MountDatasetRequest{
          name: "hello",
          version: "v1",
          key_material: {:raw_key_hex, key_material.raw_key_hex}
        },
        nil
      )

    assert mounted.encrypted
    assert File.read!(Path.join(mounted.mountpoint, "hello.txt")) == "hello world"

    wrong_key_hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    error =
      rpc_error(fn ->
        ManagerServer.read_range(read_request(key_material: {:raw_key_hex, wrong_key_hex}), nil)
      end)

    assert error.status == GRPC.Status.permission_denied()

    error = rpc_error(fn -> ManagerServer.read_range(read_request(), nil) end)
    assert error.status == GRPC.Status.invalid_argument()
  end

  test "mount -> unmount -> read with key remounts transparently" do
    key_material = publish_encrypted!()
    key = {:raw_key_hex, key_material.raw_key_hex}

    %{mountpoint: mountpoint} =
      ManagerServer.mount_dataset(
        %MountDatasetRequest{name: "hello", version: "v1", key_material: key},
        nil
      )

    assert %Abyssal.V1.UnmountDatasetResponse{} =
             ManagerServer.unmount_dataset(
               %UnmountDatasetRequest{name: "hello", version: "v1"},
               nil
             )

    refute File.exists?(Path.join(mountpoint, "hello.txt"))

    error =
      rpc_error(fn ->
        ManagerServer.unmount_dataset(%UnmountDatasetRequest{name: "hello", version: "v1"}, nil)
      end)

    assert error.status == GRPC.Status.failed_precondition()

    assert ManagerServer.read_range(read_request(key_material: key), nil).data == "hello world"
  end

  test "malformed recovery material is invalid_argument, not internal" do
    publish_encrypted!()

    error =
      rpc_error(fn ->
        ManagerServer.read_range(
          read_request(key_material: {:recovery_phrase, "not a phrase"}),
          nil
        )
      end)

    assert error.status == GRPC.Status.invalid_argument()
  end

  test "entry paths escaping the mount, missing entries and missing datasets" do
    assert {:ok, _manifest} = Publisher.publish("hello", "v1", @source)

    error =
      rpc_error(fn ->
        ManagerServer.read_range(read_request(entry_path: "../../etc/passwd"), nil)
      end)

    assert error.status == GRPC.Status.invalid_argument()

    error =
      rpc_error(fn -> ManagerServer.read_range(read_request(entry_path: "nope.txt"), nil) end)

    assert error.status == GRPC.Status.not_found()

    error = rpc_error(fn -> ManagerServer.read_range(read_request(version: "v9"), nil) end)
    assert error.status == GRPC.Status.not_found()
  end

  test "a length over the cap is invalid_argument" do
    assert {:ok, _manifest} = Publisher.publish("hello", "v1", @source)

    error =
      rpc_error(fn ->
        ManagerServer.read_range(
          read_request(length: Abyssal.Datasets.Reader.max_read_length() + 1),
          nil
        )
      end)

    assert error.status == GRPC.Status.invalid_argument()
  end
end
