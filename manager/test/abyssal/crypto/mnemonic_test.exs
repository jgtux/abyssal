defmodule Abyssal.Crypto.MnemonicTest do
  use ExUnit.Case, async: true

  alias Abyssal.Crypto.Mnemonic

  test "encode/decode round-trips across random keys" do
    for _ <- 1..20 do
      key = :crypto.strong_rand_bytes(32)
      assert {:ok, phrase} = Mnemonic.encode(key)
      assert length(String.split(phrase)) == 24
      assert {:ok, ^key} = Mnemonic.decode(phrase)
    end
  end

  test "encode rejects keys of the wrong length" do
    assert {:error, :invalid_key_length} = Mnemonic.encode(:crypto.strong_rand_bytes(16))
    assert {:error, :invalid_key_length} = Mnemonic.encode(<<>>)
  end

  test "decode rejects the wrong word count" do
    assert {:error, :invalid_word_count} = Mnemonic.decode("abandon ability able")
    assert {:error, :invalid_word_count} = Mnemonic.decode("")
  end

  test "decode rejects a word not in the wordlist" do
    {:ok, phrase} = Mnemonic.encode(:crypto.strong_rand_bytes(32))
    tampered = String.replace(phrase, ~r/^\S+/, "notarealbip39word")

    assert {:error, :unknown_word} = Mnemonic.decode(tampered)
  end

  test "decode rejects a phrase whose checksum doesn't match" do
    # A deterministic fixture rather than a randomly-tampered phrase: the
    # all-zero 32-byte key encodes to 23 "abandon"s (index 0) plus one
    # checksum word ("art"). Swapping that last word for another valid
    # wordlist entry ("abandon" again) keeps every word real but breaks
    # the checksum -- verified directly, not just assumed.
    key = :binary.copy(<<0>>, 32)
    assert {:ok, phrase} = Mnemonic.encode(key)
    assert phrase == String.duplicate("abandon ", 23) <> "art"

    tampered = String.duplicate("abandon ", 23) <> "abandon"
    assert {:error, :bad_checksum} = Mnemonic.decode(tampered)
  end
end
