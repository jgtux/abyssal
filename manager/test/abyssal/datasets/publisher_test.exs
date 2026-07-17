defmodule Abyssal.Datasets.PublisherTest do
  use ExUnit.Case, async: false

  alias Abyssal.Datasets.{Publisher, ReleaseStore}

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "abyssal_publisher_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:abyssal, :release_root, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:abyssal, :release_root)
    end)

    :ok
  end

  @tag :requires_mkdwarfs
  test "publish builds an archive and a manifest describing the source dir" do
    source = Path.join(__DIR__, "../../../../testdata/hello") |> Path.expand()

    assert {:ok, manifest} = Publisher.publish("hello", "v1", source)

    assert manifest.name == "hello"
    assert manifest.version == "v1"
    assert File.exists?(manifest.archive_path)
    assert [%{path: "hello.txt", size: 11}] = manifest.entries
    assert byte_size(manifest.archive_sha256) == 64

    assert {:ok, reloaded} = ReleaseStore.load_manifest("hello", "v1")
    assert reloaded.archive_sha256 == manifest.archive_sha256
  end

  test "publish returns an error for a missing source directory" do
    assert {:error, {:source_dir_not_found, _}} =
             Publisher.publish("nope", "v1", "/does/not/exist")
  end
end
