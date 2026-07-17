defmodule Abyssal.Crypto.KeyMaterial do
  @moduledoc """
  Resolves whichever form of key material was supplied -- raw key hex, a
  recovery phrase, or Shamir shares -- down to the raw 32-byte key.

  Shared by the manager's read_range handler and the CLI's standalone
  recover-key subcommand: recovery isn't a special-cased "disaster" path,
  it's the exact same resolution every read already goes through, just
  fed a different encoding of the same key.
  """

  alias Abyssal.Crypto.{Mnemonic, Shamir}

  @spec resolve(
          {:raw_key_hex, String.t()}
          | {:recovery_phrase, String.t()}
          | {:shares, [String.t()]}
        ) :: {:ok, <<_::256>>} | {:error, term()}
  def resolve({:raw_key_hex, hex}) do
    case Base.decode16(String.trim(hex), case: :mixed) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      {:ok, _key} -> {:error, :invalid_key_length}
      :error -> {:error, :invalid_hex}
    end
  end

  def resolve({:recovery_phrase, phrase}), do: Mnemonic.decode(phrase)

  def resolve({:shares, shares}), do: Shamir.combine(shares)
end
