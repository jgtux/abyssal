defmodule Abyssal.Crypto.ShamirTest do
  use ExUnit.Case, async: true

  alias Abyssal.Crypto.Shamir

  test "combining exactly `threshold` shares reconstructs the secret" do
    secret = :crypto.strong_rand_bytes(32)
    assert {:ok, shares} = Shamir.split(secret, 3, 5)
    assert length(shares) == 5

    assert {:ok, ^secret} = Shamir.combine(Enum.take(shares, 3))
    # Any 3 of the 5 should work, not just the first 3.
    assert {:ok, ^secret} = Shamir.combine(Enum.take(Enum.reverse(shares), 3))
  end

  test "combining more than `threshold` shares also reconstructs the secret" do
    secret = :crypto.strong_rand_bytes(32)
    assert {:ok, shares} = Shamir.split(secret, 3, 5)

    assert {:ok, ^secret} = Shamir.combine(shares)
  end

  test "combining fewer than `threshold` shares does NOT error -- it silently returns a wrong key" do
    secret = :crypto.strong_rand_bytes(32)
    assert {:ok, shares} = Shamir.split(secret, 3, 5)

    # This is documented, inherent behavior of Shamir's Secret Sharing
    # (see Shamir's moduledoc), not a bug: with fewer points than the
    # threshold, every 32-byte value is equally consistent with the
    # shares given. combine/1 has no way to know 2 was too few.
    assert {:ok, wrong_key} = Shamir.combine(Enum.take(shares, 2))
    assert wrong_key != secret
    assert byte_size(wrong_key) == 32
  end

  test "combine rejects fewer than 2 shares outright" do
    secret = :crypto.strong_rand_bytes(32)
    assert {:ok, shares} = Shamir.split(secret, 3, 5)

    assert {:error, :too_few_shares} = Shamir.combine(Enum.take(shares, 1))
    assert {:error, :too_few_shares} = Shamir.combine([])
  end

  test "combine detects a corrupted share via its checksum" do
    secret = :crypto.strong_rand_bytes(32)
    assert {:ok, [share1, share2, share3 | _]} = Shamir.split(secret, 3, 5)

    <<first_byte, rest::binary>> = Base.decode16!(share1, case: :lower)
    corrupted = Base.encode16(<<Bitwise.bxor(first_byte, 0xFF), rest::binary>>, case: :lower)

    assert {:error, {:corrupt_share, 0}} = Shamir.combine([corrupted, share2, share3])
  end

  test "combine rejects duplicate share x-coordinates" do
    secret = :crypto.strong_rand_bytes(32)
    assert {:ok, [share1, _share2, share3 | _]} = Shamir.split(secret, 3, 5)

    assert {:error, :duplicate_share_index} = Shamir.combine([share1, share1, share3])
  end

  test "split rejects an invalid threshold/total combination" do
    secret = :crypto.strong_rand_bytes(32)

    assert {:error, :invalid_arguments} = Shamir.split(secret, 1, 5)
    assert {:error, :invalid_arguments} = Shamir.split(secret, 6, 5)
    assert {:error, :invalid_arguments} = Shamir.split(<<1, 2, 3>>, 3, 5)
  end
end
