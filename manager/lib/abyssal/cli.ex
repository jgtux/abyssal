defmodule Abyssal.CLI do
  @moduledoc """
  Pure gRPC client of an already-running Abyssal.Grpc.ManagerServer (see
  mix.exs's `escript: [app: nil]` -- this process never starts
  Abyssal.Application itself). Start the manager separately first:

      mix run --no-halt

  then, from another shell:

      ./abyssal publish --name hello --version v1 --source ../testdata/hello
      ./abyssal publish --name hello --version v1 --source ../testdata/hello --profile archive
      ./abyssal read-range --name hello --version v1 --entry hello.txt --offset 0 --length 11
      ./abyssal demo

      ./abyssal publish --name hello --version v1 --source ../testdata/hello \\
        --encrypt --recovery both
      ./abyssal read-range --name hello --version v1 --entry hello.txt --offset 0 --length 11 \\
        --key <hex from publish>
      ./abyssal recover-key --phrase "24 words..."
      ./abyssal demo --encrypt
  """

  def main(args) do
    Application.ensure_all_started(:grpc)

    case args do
      ["publish" | rest] -> publish(rest)
      ["read-range" | rest] -> read_range(rest)
      ["recover-key" | rest] -> recover_key(rest)
      ["demo" | rest] -> demo(rest)
      _ -> usage()
    end
  end

  defp publish(args) do
    opts =
      parse(args,
        name: :string,
        version: :string,
        source: :string,
        encrypt: :boolean,
        recovery: :string,
        shamir_threshold: :integer,
        shamir_shares: :integer,
        profile: :string
      )

    publish_opts = [
      encrypt: opts[:encrypt] || false,
      recovery: opts[:recovery] || "",
      shamir_threshold: opts[:shamir_threshold] || 0,
      shamir_shares: opts[:shamir_shares] || 0,
      compression_profile: opts[:profile] || ""
    ]

    case call_publish(opts[:name], opts[:version], opts[:source], publish_opts) do
      {:ok, resp} ->
        IO.puts(
          "published #{opts[:name]}@#{opts[:version]} " <>
            "(#{resp.archive_path}, #{resp.entry_count} entr#{plural(resp.entry_count)})"
        )

        if resp.encrypted, do: print_key_material(resp)
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "publish failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp print_key_material(resp) do
    IO.puts(:stderr, """

    *** SAVE THIS NOW -- it will not be shown again ***
    raw key (hex): #{resp.raw_key_hex}\
    """)

    if resp.recovery_phrase != "",
      do: IO.puts(:stderr, "recovery phrase: #{resp.recovery_phrase}")

    if resp.shares != [] do
      IO.puts(:stderr, "shamir shares (#{resp.shamir_threshold}-of-#{resp.shamir_total}):")
      Enum.each(resp.shares, &IO.puts(:stderr, "  #{&1}"))
    end

    IO.puts(:stderr, "")
  end

  defp read_range(args) do
    opts =
      parse(args,
        name: :string,
        version: :string,
        entry: :string,
        offset: :integer,
        length: :integer,
        key: :string,
        phrase: :string,
        shares: :keep
      )

    key_material = key_material_from_opts(opts)

    case call_read_range(
           opts[:name],
           opts[:version],
           opts[:entry],
           opts[:offset],
           opts[:length],
           key_material
         ) do
      {:ok, resp} ->
        IO.write(resp.data)
        IO.puts(:stderr, "\n(#{resp.bytes_read} bytes, eof=#{resp.eof})")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "read-range failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # --key / --phrase / --shares are mutually exclusive; whichever is
  # present wins, checked in that order.
  defp key_material_from_opts(opts) do
    cond do
      opts[:key] ->
        {:raw_key_hex, opts[:key]}

      opts[:phrase] ->
        {:recovery_phrase, opts[:phrase]}

      true ->
        case Keyword.get_values(opts, :shares) do
          [] -> nil
          shares -> {:shares, shares}
        end
    end
  end

  defp recover_key(args) do
    opts = parse(args, phrase: :string, shares: :keep)

    key_material =
      cond do
        opts[:phrase] ->
          {:recovery_phrase, opts[:phrase]}

        true ->
          case Keyword.get_values(opts, :shares) do
            [] -> nil
            shares -> {:shares, shares}
          end
      end

    # Pure math, no gRPC connection at all -- recovery isn't a special
    # server-side flow, so this doesn't need the manager running.
    case key_material && Abyssal.Crypto.KeyMaterial.resolve(key_material) do
      nil ->
        IO.puts(:stderr, "recover-key failed: supply --phrase or --shares")
        System.halt(1)

      {:ok, key} ->
        IO.puts(Base.encode16(key, case: :lower))
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "recover-key failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp demo(args) do
    opts = parse(args, encrypt: :boolean)
    source = Path.join(__DIR__, "../../../testdata/hello") |> Path.expand()
    expected = File.read!(Path.join(source, "hello.txt"))

    if opts[:encrypt] do
      demo_encrypted(source, expected)
    else
      demo_plain(source, expected)
    end
  end

  defp demo_plain(source, expected) do
    with {:ok, _} <- call_publish("hello", "v1", source),
         {:ok, resp} <- call_read_range("hello", "v1", "hello.txt", 0, 11, nil) do
      report_match([{"plain", resp.data}], expected)
    else
      {:error, reason} ->
        IO.puts(:stderr, "demo failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Exercises all three recovery forms independently against the real
  # engine: raw key, recovery phrase, and a Shamir combine from just
  # `threshold` of the shares -- this is the feature's own acceptance
  # test, the same role plain `demo` already plays for the unencrypted
  # path. Uses a distinct version from demo_plain/2 so both can run
  # back-to-back without clobbering each other's release directory.
  defp demo_encrypted(source, expected) do
    publish_opts = [encrypt: true, recovery: "both", shamir_threshold: 3, shamir_shares: 5]

    with {:ok, pub} <- call_publish("hello", "v1-encrypted", source, publish_opts),
         {:ok, by_key} <-
           call_read_range(
             "hello",
             "v1-encrypted",
             "hello.txt",
             0,
             11,
             {:raw_key_hex, pub.raw_key_hex}
           ),
         {:ok, by_phrase} <-
           call_read_range(
             "hello",
             "v1-encrypted",
             "hello.txt",
             0,
             11,
             {:recovery_phrase, pub.recovery_phrase}
           ),
         {:ok, by_shares} <-
           call_read_range(
             "hello",
             "v1-encrypted",
             "hello.txt",
             0,
             11,
             {:shares, Enum.take(pub.shares, pub.shamir_threshold)}
           ) do
      report_match(
        [{"raw key", by_key.data}, {"phrase", by_phrase.data}, {"shares", by_shares.data}],
        expected
      )
    else
      {:error, reason} ->
        IO.puts(:stderr, "demo --encrypt failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp report_match(labeled_results, expected) do
    mismatches = for {label, data} <- labeled_results, data != expected, do: label

    if mismatches == [] do
      IO.puts("MATCH (#{labeled_results |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")})")
      System.halt(0)
    else
      IO.puts(:stderr, "MISMATCH: #{Enum.join(mismatches, ", ")} did not match source bytes")
      System.halt(1)
    end
  end

  defp call_publish(name, version, source, opts \\ []) do
    with {:ok, channel} <- connect() do
      request = %Abyssal.V1.PublishDatasetRequest{
        name: name,
        version: version,
        source_dir: source,
        encrypt: Keyword.get(opts, :encrypt, false),
        recovery: Keyword.get(opts, :recovery, ""),
        shamir_threshold: Keyword.get(opts, :shamir_threshold, 0),
        shamir_shares: Keyword.get(opts, :shamir_shares, 0),
        compression_profile: Keyword.get(opts, :compression_profile, "")
      }

      result = Abyssal.V1.AbyssalManager.Stub.publish_dataset(channel, request)
      GRPC.Stub.disconnect(channel)
      result
    end
  end

  defp call_read_range(name, version, entry, offset, length, key_material) do
    with {:ok, channel} <- connect() do
      request =
        %Abyssal.V1.ReadRangeRequest{
          name: name,
          version: version,
          entry_path: entry,
          offset: offset,
          length: length
        }
        |> apply_key_material(key_material)

      result = Abyssal.V1.AbyssalManager.Stub.read_range(channel, request)
      GRPC.Stub.disconnect(channel)
      result
    end
  end

  # ReadRangeRequest's raw_key_hex/recovery_phrase/shares are a proto3
  # `oneof`, which the protobuf lib collapses into a single struct field
  # (key_material) holding a tagged tuple -- not three separate flat
  # fields as the .proto source's field list might suggest at a glance.
  defp apply_key_material(request, nil), do: request

  defp apply_key_material(request, {:raw_key_hex, hex}),
    do: %{request | key_material: {:raw_key_hex, hex}}

  defp apply_key_material(request, {:recovery_phrase, phrase}),
    do: %{request | key_material: {:recovery_phrase, phrase}}

  defp apply_key_material(request, {:shares, shares}),
    do: %{request | key_material: {:shares, %Abyssal.V1.KeyShares{share: shares}}}

  defp connect do
    addr = System.get_env("ABYSSAL_MANAGER_ADDR", "127.0.0.1:50051")
    GRPC.Stub.connect(addr)
  end

  defp parse(args, spec) do
    {opts, _rest} = OptionParser.parse!(args, strict: spec)
    opts
  end

  defp plural(1), do: "y"
  defp plural(_), do: "ies"

  defp usage do
    IO.puts(:stderr, """
    usage: abyssal <publish|read-range|recover-key|demo> [options]

      publish      --name NAME --version VERSION --source SOURCE_DIR
                   [--profile hot|balanced|archive]
                   [--encrypt --recovery phrase|split|both]
                   [--shamir-threshold N] [--shamir-shares N]
      read-range   --name NAME --version VERSION --entry ENTRY --offset N --length N
                   [--key HEX | --phrase "words..." | --shares HEX --shares HEX ...]
      recover-key  --phrase "words..." | --shares HEX --shares HEX ...
      demo         [--encrypt]
    """)

    System.halt(1)
  end
end
