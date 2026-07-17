defmodule Abyssal.Crypto.Shamir do
  @moduledoc """
  Shamir's Secret Sharing (k-of-n threshold) over Abyssal's 256-bit
  dataset keys.

  Each of the key's 32 bytes is split independently over GF(2^8) (AES's
  field: generator 0x03, reduction polynomial x^8+x^4+x^3+x+1, i.e.
  0x11B): a random degree-(threshold-1) polynomial per byte, with that
  byte as the constant term, evaluated at `total` distinct nonzero
  x-coordinates (1..total). Reconstruction is Lagrange interpolation at
  x=0, done independently per byte.

  Share format (34 bytes, hex-encoded to 68 chars for display/storage):
  `<<x::8, y::binary-32, checksum::8>>`, where checksum is the first byte
  of SHA-256(x <> y) -- this only catches a mistyped/corrupted individual
  share, it is NOT a secret-level checksum (see combine/1 for why one
  can't exist here).

  IMPORTANT, inherent to Shamir's Secret Sharing and not a bug: combining
  fewer than the original threshold of shares does not error. With too
  few points, every 32-byte value is equally consistent with the given
  shares (that's the whole point of the scheme being information-
  theoretically secure) -- combine/1 will happily interpolate a
  plausible-looking but wrong key. There is no way to detect insufficiency
  from the shares alone. Wrongness is only ever caught downstream, when
  the reconstructed key fails AES-GCM's authentication tag on the actual
  decrypt attempt -- the same way a mistyped raw key or a garbled
  recovery phrase is caught. This is why recovery is deliberately the
  same code path as a normal read, not a separate "trust me" flow.
  """

  import Bitwise, only: [bxor: 2, bsl: 2, bsr: 2, band: 2]

  @key_bytes 32

  @doc """
  Splits `secret` (32 bytes) into `total` shares, any `threshold` of
  which reconstruct it. `threshold` must be >= 2; `total` must be
  between `threshold` and 255 (x-coordinates are single bytes, 0 is
  reserved for the secret's own evaluation point).
  """
  @spec split(<<_::256>>, pos_integer(), pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
  def split(secret, threshold, total)
      when is_binary(secret) and byte_size(secret) == @key_bytes and
             is_integer(threshold) and threshold >= 2 and
             is_integer(total) and total >= threshold and total <= 255 do
    xs = Enum.to_list(1..total)
    secret_bytes = :binary.bin_to_list(secret)

    # One random polynomial per secret byte; evaluate each at every x.
    ys_per_byte =
      Enum.map(secret_bytes, fn byte ->
        coeffs = [byte | for(_ <- 2..threshold, do: random_byte())]
        Enum.map(xs, &eval_poly(coeffs, &1))
      end)

    shares =
      xs
      |> Enum.zip(transpose(ys_per_byte))
      |> Enum.map(fn {x, ys} ->
        y = :binary.list_to_bin(ys)
        checksum = share_checksum(x, y)
        Base.encode16(<<x::8, y::binary, checksum::8>>, case: :lower)
      end)

    {:ok, shares}
  end

  def split(_secret, _threshold, _total), do: {:error, :invalid_arguments}

  @doc """
  Reconstructs the original 32-byte secret from a list of hex-encoded
  shares (as produced by split/3). Requires at least 2 shares with
  distinct, checksum-valid x-coordinates; see the moduledoc for what
  happens with fewer shares than the original threshold.
  """
  @spec combine([String.t()]) ::
          {:ok, <<_::256>>}
          | {:error,
             {:corrupt_share, non_neg_integer()} | :too_few_shares | :duplicate_share_index}
  def combine(shares) when is_list(shares) do
    with {:ok, parsed} <- parse_shares(shares),
         :ok <- validate_shares(parsed) do
      {:ok, reconstruct(parsed)}
    end
  end

  defp parse_shares(shares) do
    shares
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, idx}, {:ok, acc} ->
      case parse_share(raw, idx) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp parse_share(raw, idx) do
    with {:ok, bin} <- Base.decode16(String.trim(raw), case: :mixed),
         <<x::8, y::binary-size(@key_bytes), checksum::8>> <- bin,
         true <- share_checksum(x, y) == checksum do
      {:ok, {x, y}}
    else
      _ -> {:error, {:corrupt_share, idx}}
    end
  end

  defp validate_shares(parsed) do
    cond do
      length(parsed) < 2 ->
        {:error, :too_few_shares}

      length(Enum.uniq_by(parsed, fn {x, _y} -> x end)) != length(parsed) ->
        {:error, :duplicate_share_index}

      true ->
        :ok
    end
  end

  defp reconstruct(parsed) do
    xs = Enum.map(parsed, fn {x, _y} -> x end)
    y_lists = Enum.map(parsed, fn {_x, y} -> :binary.bin_to_list(y) end)

    key_bytes =
      for i <- 0..(@key_bytes - 1) do
        points = Enum.zip(xs, Enum.map(y_lists, &Enum.at(&1, i)))
        lagrange_at_zero(points)
      end

    :binary.list_to_bin(key_bytes)
  end

  # Lagrange interpolation evaluated at x=0. In GF(2^8), subtraction is
  # the same as addition (XOR), so (0 - x_j) = x_j and (x_i - x_j) = x_i
  # xor x_j.
  defp lagrange_at_zero(points) do
    Enum.reduce(points, 0, fn {xi, yi}, acc ->
      numerator =
        Enum.reduce(points, 1, fn
          {xj, _}, num when xj == xi -> num
          {xj, _}, num -> gf_mul(num, xj)
        end)

      denominator =
        Enum.reduce(points, 1, fn
          {xj, _}, den when xj == xi -> den
          {xj, _}, den -> gf_mul(den, gf_add(xi, xj))
        end)

      term = gf_mul(yi, gf_mul(numerator, gf_inv(denominator)))
      gf_add(acc, term)
    end)
  end

  defp share_checksum(x, y) do
    <<checksum, _rest::binary>> = :crypto.hash(:sha256, <<x::8, y::binary>>)
    checksum
  end

  defp random_byte, do: :crypto.strong_rand_bytes(1) |> :binary.first()

  # Horner's method, evaluated in GF(2^8).
  defp eval_poly(coeffs, x) do
    coeffs
    |> Enum.reverse()
    |> Enum.reduce(0, fn coeff, acc -> gf_add(gf_mul(acc, x), coeff) end)
  end

  defp transpose(lists) do
    lists
    |> Enum.zip()
    |> Enum.map(&Tuple.to_list/1)
  end

  defp gf_add(a, b), do: bxor(a, b)

  # "Russian peasant" GF(2^8) multiplication with AES's reduction
  # polynomial (x^8+x^4+x^3+x+1, 0x11B -- the top bit is implicit, so the
  # reduction constant applied here is 0x1B).
  defp gf_mul(a, b), do: gf_mul(a, b, 0)

  defp gf_mul(_a, 0, acc), do: acc

  defp gf_mul(a, b, acc) do
    acc = if band(b, 1) == 1, do: bxor(acc, a), else: acc
    hi_bit_set = band(a, 0x80) != 0
    a = band(bsl(a, 1), 0xFF)
    a = if hi_bit_set, do: bxor(a, 0x1B), else: a
    gf_mul(a, bsr(b, 1), acc)
  end

  defp gf_pow(_base, 0), do: 1
  defp gf_pow(base, 1), do: base

  defp gf_pow(base, exp) when rem(exp, 2) == 0 do
    half = gf_pow(base, div(exp, 2))
    gf_mul(half, half)
  end

  defp gf_pow(base, exp), do: gf_mul(base, gf_pow(base, exp - 1))

  # a^254 = a^-1 in GF(2^8)* (order 255), by Fermat's little theorem for
  # finite fields. Only ever called with a nonzero xi xor xj -- validated
  # by distinct-x-coordinate checks upstream, so no division by zero.
  defp gf_inv(a), do: gf_pow(a, 254)
end
