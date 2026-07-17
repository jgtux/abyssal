defmodule Abyssal.Crypto.Mnemonic do
  @moduledoc """
  BIP39-style recovery phrase encode/decode for Abyssal's 256-bit dataset
  keys.

  Deliberately NOT full BIP39: standard BIP39 treats the phrase as a seed
  that gets stretched via PBKDF2 into a wallet's HD tree. Abyssal is
  recovering one fixed 256-bit key, not deriving a tree, so this is kept
  directly invertible -- encode/1 and decode/1 are exact inverses, no KDF
  in between. Only the mnemonic *encoding* (wordlist + checksum scheme) is
  borrowed from BIP39, hence "BIP39-style".

  256 bits of entropy (the raw key) + an 8-bit checksum (the first byte of
  SHA-256(entropy)) = 264 bits = 24 groups of 11 bits = 24 words.
  """

  # Loaded at compile time and baked into the module as literal bytecode,
  # not read from disk at runtime -- the CLI ships as a packed escript
  # (escript: [app: nil] in mix.exs) which can't reliably expose priv/ as
  # a real filesystem path. @external_resource also makes Mix recompile
  # this module if the wordlist file changes.
  @external_resource Path.join([__DIR__, "..", "..", "..", "priv", "bip39_wordlist_en.txt"])
  @words @external_resource
         |> File.read!()
         |> String.split("\n", trim: true)

  @word_count 2048
  @key_bytes 32
  @word_total 24

  true = length(@words) == @word_count

  @word_indices @words |> Enum.with_index() |> Map.new()

  @doc """
  Encodes a 32-byte key as a 24-word recovery phrase.
  """
  @spec encode(<<_::256>>) :: {:ok, String.t()} | {:error, :invalid_key_length}
  def encode(key) when is_binary(key) and byte_size(key) == @key_bytes do
    <<checksum::bitstring-size(8), _rest::bitstring>> = :crypto.hash(:sha256, key)
    bits = <<key::binary, checksum::bitstring>>

    phrase =
      for(<<index::11 <- bits>>, do: Enum.at(@words, index))
      |> Enum.join(" ")

    {:ok, phrase}
  end

  def encode(_key), do: {:error, :invalid_key_length}

  @doc """
  Decodes a 24-word recovery phrase back to its original 32-byte key,
  rejecting phrases with the wrong word count, words outside the
  wordlist, or a checksum that doesn't match (a strong signal of a typo
  or a corrupted/garbled phrase -- not proof positive, since a mistyped
  phrase can coincidentally produce a valid-looking checksum, but this
  catches the overwhelming majority of input errors).
  """
  @spec decode(String.t()) ::
          {:ok, <<_::256>>} | {:error, :invalid_word_count | :unknown_word | :bad_checksum}
  def decode(phrase) when is_binary(phrase) do
    words = phrase |> String.trim() |> String.split(~r/\s+/, trim: true)

    if length(words) != @word_total do
      {:error, :invalid_word_count}
    else
      with {:ok, indices} <- indices_for(words) do
        bits = for(index <- indices, into: <<>>, do: <<index::11>>)
        <<key::binary-size(@key_bytes), checksum::bitstring-size(8)>> = bits
        <<expected::bitstring-size(8), _rest::bitstring>> = :crypto.hash(:sha256, key)

        if checksum == expected do
          {:ok, key}
        else
          {:error, :bad_checksum}
        end
      end
    end
  end

  defp indices_for(words) do
    words
    |> Enum.reduce_while({:ok, []}, fn word, {:ok, acc} ->
      case Map.fetch(@word_indices, word) do
        {:ok, idx} -> {:cont, {:ok, [idx | acc]}}
        :error -> {:halt, {:error, :unknown_word}}
      end
    end)
    |> case do
      {:ok, indices} -> {:ok, Enum.reverse(indices)}
      error -> error
    end
  end
end
