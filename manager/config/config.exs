import Config

config :abyssal,
  grpc_port: 50051,
  engine_addr: System.get_env("ABYSSAL_ENGINE_ADDR", "127.0.0.1:50052"),
  release_root: System.get_env("ABYSSAL_RELEASE_ROOT", "data/releases")
