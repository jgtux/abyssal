defmodule Abyssal.Application do
  use Application

  def start(_type, _args) do
    port = Application.get_env(:abyssal, :grpc_port, 50051)

    children = [
      Abyssal.ZfsMonitor.Cache,
      # Before the gRPC listener: ReadRange/MountDataset call into it, and
      # it must have cleaned up any stale mounts before the first request.
      Abyssal.Datasets.Mounts,
      {GRPC.Server.Supervisor,
       servers: [Abyssal.Grpc.ManagerServer, Abyssal.Grpc.ZfsMonitorServer],
       port: port,
       start_server: true}
    ]

    opts = [strategy: :one_for_one, name: Abyssal.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
