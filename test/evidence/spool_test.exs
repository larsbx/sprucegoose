defmodule SpruceGoose.Evidence.SpoolTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias SpruceGoose.Evidence.Spool

  setup do
    dir = Path.join(System.tmp_dir!(), "sg-spool-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "writes atomically with mode 0600 and returns handle, size, digest", %{dir: dir} do
    bytes = "canonical-payload"
    assert {:ok, r} = Spool.write(dir, "snap-1", bytes)
    assert r.byte_count == byte_size(bytes)
    assert r.sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert File.read!(r.path) == bytes
    stat = File.stat!(r.path)
    assert (stat.mode &&& 0o777) == 0o600
  end

  test "refuses to overwrite an existing artifact", %{dir: dir} do
    assert {:ok, _} = Spool.write(dir, "snap-dup", "a")
    assert {:error, :artifact_exists} = Spool.write(dir, "snap-dup", "b")
  end

  test "refuses payloads over the declared bound", %{dir: dir} do
    huge = :binary.copy("x", SpruceGoose.Evidence.Bounds.declared()[:serialized_bytes] + 1)
    assert {:error, {:bound_exceeded, :serialized_bytes, _, _}} = Spool.write(dir, "snap-big", huge)
    refute File.exists?(Path.join(dir, "snap-big.json"))
  end

  test "does not follow a symlink at the target path", %{dir: dir} do
    target = Path.join(dir, "snap-link.json")
    decoy = Path.join(dir, "decoy")
    File.write!(decoy, "original")
    :ok = File.ln_s(decoy, target)
    assert {:error, reason} = Spool.write(dir, "snap-link", "attacker")
    assert reason in [:artifact_exists, :unsafe_target]
    assert File.read!(decoy) == "original"
  end

  test "read-back verification detects a digest mismatch", %{dir: dir} do
    assert {:ok, r} = Spool.write(dir, "snap-rb", "genuine")
    File.write!(r.path, "tampered")
    assert {:error, :readback_mismatch} = Spool.verify(r)
  end
end
