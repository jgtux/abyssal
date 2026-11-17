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
