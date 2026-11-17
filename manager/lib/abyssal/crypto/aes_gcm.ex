defmodule Abyssal.Crypto.AesGcm do
  @moduledoc """
  AES-256-GCM whole-archive encryption, and the single canonical owner of
  Abyssal's on-disk encrypted-archive format, in both directions:

      offset 0..4    magic:   4 bytes, ASCII "ABY1"
      offset 4..16   nonce:   12 bytes (AES-GCM standard IV), random per publish
      offset 16..EOF ciphertext with its 16-byte GCM tag appended

  Whole-archive, not chunked: the dwarfs FUSE driver needs one complete
  plaintext image file to mount, and OTP's :crypto has no streaming
  AES-GCM (only crypto_one_time_aead), so both encrypt and decrypt hold
  the whole archive in memory once. Acceptable at this project's current
  scale; a chunked-AEAD format is the fix if it stops being.

  This used to be split across two languages (encrypt here, decrypt in a
  Rust engine mirroring these constants byte-for-byte). Keeping both
  directions in one module removes that cross-language contract entirely.
  """

  @magic "ABY1"
  @nonce_len 12
  @tag_len 16
  @key_len 32

  @doc "Generates a fresh random 256-bit key."
  @spec generate_key() :: <<_::256>>
  def generate_key, do: :crypto.strong_rand_bytes(@key_len)

  @doc """
  Encrypts `plaintext` under `key` with a freshly generated random nonce.
  Returns the nonce separately (also mirrored into the manifest for
  operator visibility) and the ciphertext with its 16-byte GCM tag
  appended.
  """
  @spec encrypt(binary(), <<_::256>>) :: {nonce :: <<_::96>>, ciphertext_with_tag :: binary()}
  def encrypt(plaintext, key) when is_binary(key) and byte_size(key) == @key_len do
    nonce = :crypto.strong_rand_bytes(@nonce_len)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, "", true)

    {nonce, ciphertext <> tag}
  end

  @doc """
  Decrypts `ciphertext_with_tag` under `key` and `nonce`. A wrong key and
  a tampered/corrupted ciphertext are indistinguishable from AES-GCM's
  perspective -- both surface as `{:error, :decrypt_failed}`, and callers
  shouldn't over-claim which one it was.
  """
  @spec decrypt(binary(), <<_::96>>, binary()) ::
          {:ok, binary()} | {:error, :invalid_key | :decrypt_failed}
  def decrypt(key, _nonce, _ciphertext_with_tag)
      when not is_binary(key) or byte_size(key) != @key_len,
      do: {:error, :invalid_key}

  def decrypt(_key, _nonce, ciphertext_with_tag) when byte_size(ciphertext_with_tag) < @tag_len,
    do: {:error, :decrypt_failed}

  def decrypt(key, nonce, ciphertext_with_tag) do
    ct_len = byte_size(ciphertext_with_tag) - @tag_len
    <<ciphertext::binary-size(^ct_len), tag::binary-size(@tag_len)>> = ciphertext_with_tag

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, "", tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decrypt_failed}
    end
  end

  @doc "Builds the on-disk format: magic <> nonce <> ciphertext_with_tag."
  @spec wrap(<<_::96>>, binary()) :: binary()
  def wrap(nonce, ciphertext_with_tag) when byte_size(nonce) == @nonce_len do
    @magic <> nonce <> ciphertext_with_tag
  end

  @doc """
  Inverse of `wrap/2`. Anything too short to hold the header plus a GCM
  tag, or missing the magic, is `{:error, :corrupt_archive}` -- the file
  isn't even well-formed, which is a different operator problem than a
  wrong key.
  """
  @spec unwrap(binary()) :: {:ok, <<_::96>>, binary()} | {:error, :corrupt_archive}
  def unwrap(<<@magic, nonce::binary-size(@nonce_len), rest::binary>>)
      when byte_size(rest) >= @tag_len,
      do: {:ok, nonce, rest}

  def unwrap(_data), do: {:error, :corrupt_archive}

  @doc """
  Sniffs the first 4 bytes of `path` for the magic header. Genuine DwarFS
  images start with their own distinct "DWARFS" superblock magic, so
  there's no collision risk.
  """
  @spec encrypted_file?(Path.t()) :: boolean()
  def encrypted_file?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, byte_size(@magic))) do
      {:ok, @magic} -> true
      _ -> false
    end
  end
end
