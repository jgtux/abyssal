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

  @tag :requires_mkdwarfs
  test "encrypted publish returns a 3-tuple, leaves unencrypted publish/3's 2-tuple contract alone" do
    source = Path.join(__DIR__, "../../../../testdata/hello") |> Path.expand()

    assert {:ok, plain_manifest} = Publisher.publish("hello", "plain", source)
    assert plain_manifest.encrypted == false

    assert {:ok, enc_manifest, key_material} =
             Publisher.publish("hello", "enc", source, encrypt: true, recovery: :both)

    assert enc_manifest.encrypted == true
    assert enc_manifest.cipher == "aes-256-gcm"
    assert byte_size(Base.decode16!(enc_manifest.nonce, case: :lower)) == 12

    assert byte_size(Base.decode16!(key_material.raw_key_hex, case: :lower)) == 32
    assert key_material.recovery_phrase != nil
    assert length(String.split(key_material.recovery_phrase)) == 24
    assert length(key_material.shares) == 5
    assert key_material.shamir_threshold == 3
    assert key_material.shamir_total == 5

    # archive_sha256 hashes whatever is physically on disk -- proves it's
    # hashing ciphertext, not the plaintext both publishes started from.
    assert plain_manifest.archive_sha256 != enc_manifest.archive_sha256

    # The on-disk file is the wrapped ciphertext, not the plaintext
    # mkdwarfs originally wrote.
    on_disk = File.read!(enc_manifest.archive_path)
    assert binary_part(on_disk, 0, 4) == "ABY1"

    assert {:ok, reloaded} = ReleaseStore.load_manifest("hello", "enc")
    assert reloaded.encrypted == true
    assert reloaded.cipher == "aes-256-gcm"
  end

  @tag :requires_mkdwarfs
  test "encrypted publish requires a valid recovery option" do
    source = Path.join(__DIR__, "../../../../testdata/hello") |> Path.expand()

    assert {:error, {:invalid_recovery, nil}} =
             Publisher.publish("hello", "bad-recovery", source, encrypt: true)

    assert {:error, {:invalid_recovery, "nonsense"}} =
             Publisher.publish("hello", "bad-recovery-2", source,
               encrypt: true,
               recovery: "nonsense"
             )
  end
end
