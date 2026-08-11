defmodule SpruceGoose.AuthorityRuntimeTest do
  use ExUnit.Case, async: false

  alias SpruceGoose.AuthorityRuntime

  setup do
    path = Path.join(System.tmp_dir!(), "authority-host-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:spruce_goose, :authority_host_marker)
    Application.put_env(:spruce_goose, :authority_host_marker, path)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:spruce_goose, :authority_host_marker, prior),
        else: Application.delete_env(:spruce_goose, :authority_host_marker)
    end)

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
