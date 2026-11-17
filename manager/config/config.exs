import Config

config :abyssal,
  grpc_port: 50051,
  release_root: System.get_env("ABYSSAL_RELEASE_ROOT", "data/releases"),
  # README's Mounted mode: every dataset is mounted at
  # <mount_root>/<name>/<version> via the dwarfs FUSE driver.
  mount_root: System.get_env("ABYSSAL_MOUNT_ROOT", "/mnt/abyssal"),
  # Decrypted images of mounted encrypted datasets live here, and only
  # while mounted. Default is RAM-backed tmpfs so plaintext never touches
  # persistent storage -- see Abyssal.Datasets.Mounts.
  decrypt_root: System.get_env("ABYSSAL_DECRYPT_ROOT", "/dev/shm/abyssal"),
  dwarfs_bin: System.get_env("ABYSSAL_DWARFS_BIN", "dwarfs"),
  fusermount_bin: System.get_env("ABYSSAL_FUSERMOUNT_BIN", "fusermount3")

# The application (and so Datasets.Mounts, whose init wipes decrypt_root
# and unmounts stale mounts under mount_root) boots for every `mix test`.
# Never let that touch a dev manager's real roots running alongside it;
# individual tests further isolate themselves via
# Abyssal.Test.IsolatedRoots.
if config_env() == :test do
  test_root = Path.join(System.tmp_dir!(), "abyssal_test_app")

  config :abyssal,
    release_root: Path.join(test_root, "releases"),
    mount_root: Path.join(test_root, "mnt"),
    decrypt_root: Path.join(test_root, "shm")
end
