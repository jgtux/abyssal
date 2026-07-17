defmodule Abyssal.MixProject do
  use Mix.Project

  def project do
    [
      app: :abyssal,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Abyssal.Application, []}
    ]
  end

  defp escript do
    # app: nil -- the CLI is a pure gRPC *client* of an already-running
    # manager server, so it must not also boot Abyssal.Application (which
    # would try to bind the same gRPC port as a server).
    [main_module: Abyssal.CLI, app: nil]
  end

  defp aliases do
    [
      # `mix cmd` does not go through a shell, so a `*.proto` glob is
      # never expanded -- list files explicitly. Each proto_path points
      # directly at the file's own directory (rather than the shared
      # ../proto root) so protoc doesn't ALSO nest output by the file's
      # path-relative-to-proto_path on top of protoc-gen-elixir's own
      # package-based nesting -- confirmed empirically: proto_path=../proto
      # produced a doubled lib/abyssal/v1/abyssal/v1/manager.pb.ex.
      "protobuf.generate": [
        "cmd protoc --elixir_out=plugins=grpc:./lib --proto_path=priv/protos priv/protos/zfs_monitor.proto",
        "cmd protoc --elixir_out=plugins=grpc:./lib --proto_path=../proto/abyssal/v1 ../proto/abyssal/v1/manager.proto",
        "cmd protoc --elixir_out=plugins=grpc:./lib --proto_path=../proto/abyssal/engine/v1 ../proto/abyssal/engine/v1/engine.proto"
      ]
    ]
  end

  defp deps do
    [
      # ~> 0.7 (the grpc-zfs-monitor-demo pin) resolves to 0.11.5, which
      # Hex's own advisory audit flags for several HIGH-severity CVEs
      # (unsafe term deserialization -> RCE, gzip bomb, unbounded body
      # accumulation, authz bypass). 1.0+ is the current stable line with
      # those fixed.
      {:grpc, "~> 1.0"},
      # grpc 1.0 split server functionality (GRPC.Server,
      # GRPC.Server.Supervisor) into this separate package.
      {:grpc_server, "~> 1.0"},
      # grpc's client transport adapter (Gun) is an optional peer dep, not
      # pulled in automatically -- GRPC.Stub.connect/2 defaults to it.
      {:gun, "~> 2.4"},
      {:protobuf, "~> 0.12"},
      {:jason, "~> 1.4"}
    ]
  end
end
