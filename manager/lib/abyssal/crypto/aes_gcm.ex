defmodule Abyssal.Crypto.AesGcm do
  @moduledoc """
  AES-256-GCM encryption for whole-archive encryption at publish time.

  Decryption always happens engine-side (Rust, see engine/src/crypto.rs)
  -- mount_root_memfs takes one pointer+length upfront, so there's no
  streaming/block-level hook to decrypt through; the whole archive is
  encrypted as one AEAD blob and decrypted into an owned buffer before
  the engine ever mounts it. This module only ever encrypts.
  """

  @magic "ABY1"
  @nonce_len 12
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
  The single canonical definition of Abyssal's on-disk encrypted-archive
  format: magic <> nonce <> ciphertext_with_tag. Mirrored byte-for-byte by
  engine/src/crypto.rs's MAGIC/NONCE_LEN constants and decrypt_archive/2
  -- both sides must agree on this exactly, it's the cross-language
  contract for the whole feature.
  """
  @spec wrap(<<_::96>>, binary()) :: binary()
  def wrap(nonce, ciphertext_with_tag) when byte_size(nonce) == @nonce_len do
    @magic <> nonce <> ciphertext_with_tag
  end
end
