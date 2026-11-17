defmodule Abyssal.Crypto.AesGcmTest do
  use ExUnit.Case, async: true

  alias Abyssal.Crypto.AesGcm

  setup do
    {:ok, key: AesGcm.generate_key(), plaintext: "the quick brown fox"}
  end

  test "encrypt -> wrap -> unwrap -> decrypt round-trips", %{key: key, plaintext: plaintext} do
    {nonce, ct} = AesGcm.encrypt(plaintext, key)

    assert {:ok, ^nonce, ^ct} = AesGcm.unwrap(AesGcm.wrap(nonce, ct))
    assert {:ok, ^plaintext} = AesGcm.decrypt(key, nonce, ct)
  end

  test "a wrong key is :decrypt_failed", %{key: key, plaintext: plaintext} do
    {nonce, ct} = AesGcm.encrypt(plaintext, key)
    assert {:error, :decrypt_failed} = AesGcm.decrypt(AesGcm.generate_key(), nonce, ct)
  end

  test "a tampered ciphertext is :decrypt_failed", %{key: key, plaintext: plaintext} do
    {nonce, <<first, rest::binary>>} = AesGcm.encrypt(plaintext, key)

    assert {:error, :decrypt_failed} =
             AesGcm.decrypt(key, nonce, <<Bitwise.bxor(first, 1), rest::binary>>)
  end

  test "a key of the wrong length is :invalid_key", %{key: key, plaintext: plaintext} do
    {nonce, ct} = AesGcm.encrypt(plaintext, key)
    assert {:error, :invalid_key} = AesGcm.decrypt(binary_part(key, 0, 16), nonce, ct)
  end

  test "unwrap rejects truncated or non-ABY1 data as :corrupt_archive" do
    assert {:error, :corrupt_archive} = AesGcm.unwrap("ABY1short")
    assert {:error, :corrupt_archive} = AesGcm.unwrap("")
    assert {:error, :corrupt_archive} = AesGcm.unwrap("DWARFS" <> :binary.copy(<<0>>, 64))
  end

  @tag :tmp_dir
  test "encrypted_file?/1 sniffs the magic", %{tmp_dir: tmp, key: key, plaintext: plaintext} do
    {nonce, ct} = AesGcm.encrypt(plaintext, key)
    enc = Path.join(tmp, "enc")
    plain = Path.join(tmp, "plain")
    File.write!(enc, AesGcm.wrap(nonce, ct))
    File.write!(plain, "DWARFS....")

    assert AesGcm.encrypted_file?(enc)
    refute AesGcm.encrypted_file?(plain)
    refute AesGcm.encrypted_file?(Path.join(tmp, "missing"))
  end
end
