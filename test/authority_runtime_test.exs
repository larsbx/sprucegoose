defmodule SpruceGoose.AuthorityRuntimeTest do
  use ExUnit.Case, async: false

  alias SpruceGoose.AuthorityRuntime

  # Use ExUnit's per-test tmp_dir, never a shared /tmp filename.
  #
  # `System.unique_integer/1` is per-VM and restarts from a low base on every
  # run, so a shared "authority-host-<int>" path in tmp_dir eventually collides
  # with a leftover file written by an earlier run. When that stale file holds a
  # delegated host, the "missing marker" case reads it and fails with
  # `authority is mama`. @tag :tmp_dir gives a path unique per test that ExUnit
  # clears before the test runs.
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "authority-host")

    configured = Application.fetch_env!(:spruce_goose, :authority_host_marker)
    Application.put_env(:spruce_goose, :authority_host_marker, path)
    on_exit(fn -> Application.put_env(:spruce_goose, :authority_host_marker, configured) end)

    %{path: path}
  end

  test "missing or local markers allow direct execution", %{path: path} do
    assert :ok = AuthorityRuntime.ensure_local_execution_allowed()
    File.write!(path, "local\n")
    assert :ok = AuthorityRuntime.ensure_local_execution_allowed()
  end

  test "a delegated host marker refuses direct execution", %{path: path} do
    File.write!(path, "mama\n")

    assert {:error, message} = AuthorityRuntime.ensure_local_execution_allowed()
    assert message =~ "authority is mama"
    assert message =~ "supported socket client"
  end
end
