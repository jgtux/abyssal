defmodule Abyssal.Datasets.ReaderTest do
  use ExUnit.Case, async: true

  alias Abyssal.Datasets.Reader

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "root")
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "hello.txt"), "hello world")
    File.write!(Path.join(root, "sub/nested.txt"), "nested")
    File.write!(Path.join(tmp, "outside.txt"), "secret")
    {:ok, root: root}
  end

  test "whole file from offset zero", %{root: root} do
    assert {:ok, "hello world", true} = Reader.read_range(root, "hello.txt", 0, 11)
  end

  test "non-zero offset, not reaching eof", %{root: root} do
    assert {:ok, "lo w", false} = Reader.read_range(root, "hello.txt", 3, 4)
  end

  test "a length past the end is truncated and eof", %{root: root} do
    assert {:ok, "world", true} = Reader.read_range(root, "hello.txt", 6, 100)
  end

  test "an offset at or past the end is empty and eof", %{root: root} do
    assert {:ok, "", true} = Reader.read_range(root, "hello.txt", 11, 5)
    assert {:ok, "", true} = Reader.read_range(root, "hello.txt", 50, 5)
  end

  test "nested entries and a leading slash resolve inside root", %{root: root} do
    assert {:ok, "nested", true} = Reader.read_range(root, "sub/nested.txt", 0, 6)
    assert {:ok, "nested", true} = Reader.read_range(root, "/sub/nested.txt", 0, 6)
  end

  test "a length over the cap is rejected without touching the filesystem" do
    assert {:error, :length_too_large} =
             Reader.read_range("/nonexistent", "x", 0, Reader.max_read_length() + 1)
  end

  test "entry paths escaping root are rejected", %{root: root} do
    assert {:error, :invalid_entry_path} = Reader.read_range(root, "../outside.txt", 0, 6)
    assert {:error, :invalid_entry_path} = Reader.read_range(root, "sub/../../outside.txt", 0, 6)
    assert {:error, :invalid_entry_path} = Reader.read_range(root, "", 0, 6)
  end

  test "a symlink pointing outside root is rejected", %{root: root, tmp_dir: tmp} do
    File.ln_s!(Path.join(tmp, "outside.txt"), Path.join(root, "link.txt"))
    assert {:error, :invalid_entry_path} = Reader.read_range(root, "link.txt", 0, 6)
  end

  test "a missing entry is :enoent and a directory is :eisdir", %{root: root} do
    assert {:error, :enoent} = Reader.read_range(root, "nope.txt", 0, 1)
    assert {:error, :eisdir} = Reader.read_range(root, "sub", 0, 1)
  end
end
