defmodule Abyssal.Test.IsolatedRoots do
  @moduledoc """
  Points release_root, mount_root and decrypt_root at a fresh per-test
  temp dir, and undoes it on exit.

  Ordering in on_exit matters: everything mounted during the test is
  unmounted *before* the temp dir is removed -- rm_rf over a live FUSE
  mount fails partway (the image is read-only) and leaves the mount
  dangling for the next test, which then reuses the same name/version.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  @keys [:release_root, :mount_root, :decrypt_root]

  def setup_isolated_roots(_context \\ %{}) do
    tmp = Path.join(System.tmp_dir!(), "abyssal_test_#{System.unique_integer([:positive])}")
    previous = Map.new(@keys, &{&1, Application.fetch_env(:abyssal, &1)})

    roots = %{
      release_root: Path.join(tmp, "releases"),
      mount_root: Path.join(tmp, "mnt"),
      decrypt_root: Path.join(tmp, "shm")
    }

    Enum.each(roots, fn {key, dir} ->
      File.mkdir_p!(dir)
      Application.put_env(:abyssal, key, dir)
    end)

    on_exit(fn ->
      Abyssal.Datasets.Mounts.unmount_all()
      File.rm_rf!(tmp)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:abyssal, key, value)
        {key, :error} -> Application.delete_env(:abyssal, key)
      end)
    end)

    {:ok, roots}
  end
end
