defmodule Abyssal.CLI do
  @moduledoc """
  Pure gRPC client of an already-running Abyssal.Grpc.ManagerServer (see
  mix.exs's `escript: [app: nil]` -- this process never starts
  Abyssal.Application itself). Start the manager separately first:

      mix run --no-halt

  then, from another shell:

      ./abyssal publish --name hello --version v1 --source ../testdata/hello
      ./abyssal read-range --name hello --version v1 --entry hello.txt --offset 0 --length 11
      ./abyssal demo
  """

  def main(args) do
    Application.ensure_all_started(:grpc)

    case args do
      ["publish" | rest] -> publish(rest)
      ["read-range" | rest] -> read_range(rest)
      ["demo" | rest] -> demo(rest)
      _ -> usage()
    end
  end

  defp publish(args) do
    opts = parse(args, name: :string, version: :string, source: :string)

    case call_publish(opts[:name], opts[:version], opts[:source]) do
      {:ok, resp} ->
        IO.puts(
          "published #{opts[:name]}@#{opts[:version]} " <>
            "(#{resp.archive_path}, #{resp.entry_count} entr#{plural(resp.entry_count)})"
        )

        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "publish failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp read_range(args) do
    opts =
      parse(args,
        name: :string,
        version: :string,
        entry: :string,
        offset: :integer,
        length: :integer
      )

    case call_read_range(opts[:name], opts[:version], opts[:entry], opts[:offset], opts[:length]) do
      {:ok, resp} ->
        IO.write(resp.data)
        IO.puts(:stderr, "\n(#{resp.bytes_read} bytes, eof=#{resp.eof})")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "read-range failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp demo(_args) do
    source = Path.join(__DIR__, "../../../testdata/hello") |> Path.expand()

    with {:ok, _} <- call_publish("hello", "v1", source),
         {:ok, resp} <- call_read_range("hello", "v1", "hello.txt", 0, 11),
         expected <- File.read!(Path.join(source, "hello.txt")) do
      if resp.data == expected do
        IO.puts("MATCH")
        System.halt(0)
      else
        IO.puts(:stderr, "MISMATCH: got #{inspect(resp.data)}, want #{inspect(expected)}")
        System.halt(1)
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, "demo failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp call_publish(name, version, source) do
    with {:ok, channel} <- connect() do
      request = %Abyssal.V1.PublishDatasetRequest{
        name: name,
        version: version,
        source_dir: source
      }

      result = Abyssal.V1.AbyssalManager.Stub.publish_dataset(channel, request)
      GRPC.Stub.disconnect(channel)
      result
    end
  end

  defp call_read_range(name, version, entry, offset, length) do
    with {:ok, channel} <- connect() do
      request = %Abyssal.V1.ReadRangeRequest{
        name: name,
        version: version,
        entry_path: entry,
        offset: offset,
        length: length
      }

      result = Abyssal.V1.AbyssalManager.Stub.read_range(channel, request)
      GRPC.Stub.disconnect(channel)
      result
    end
  end

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
    usage: abyssal <publish|read-range|demo> [options]

      publish     --name NAME --version VERSION --source SOURCE_DIR
      read-range  --name NAME --version VERSION --entry ENTRY --offset N --length N
      demo
    """)

    System.halt(1)
  end
end
