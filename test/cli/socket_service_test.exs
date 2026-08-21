defmodule SpruceGoose.CLI.SocketServiceTest do
  use ExUnit.Case, async: true

  test "the thin client reaches a concurrent Bandit Unix-socket service" do
    socket_path =
      Path.join(System.tmp_dir!(), "sprucegoose-#{System.unique_integer([:positive])}.sock")

    supervisor = start_supervised!(Task.Supervisor)

    runner = fn
      ["version"] -> {:ok, %{version: "socket-test"}}
      _ -> {:error, "unexpected command"}
    end

    start_supervised!(
      {Bandit,
       plug: {SpruceGoose.CLI.SocketPlug, runner: runner, supervisor: supervisor, timeout: 100},
       scheme: :http,
       ip: {:local, socket_path},
       port: 0,
       startup_log: false}
    )

    on_exit(fn -> File.rm(socket_path) end)

    {output, status} =
      System.cmd("python3", ["scripts/sprucegoose-client.py", "version"],
        env: [{"SPRUCE_GOOSE_CLI_SOCKET", socket_path}]
      )

    assert status == 0
    assert Jason.decode!(output) == %{"ok" => true, "version" => "socket-test"}
  end

  test "the thin client fails fast when the service is unavailable" do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "missing-sprucegoose-#{System.unique_integer([:positive])}.sock"
      )

    started_at = System.monotonic_time(:millisecond)

    {output, status} =
      System.cmd("python3", ["scripts/sprucegoose-client.py", "version"],
        env: [{"SPRUCE_GOOSE_CLI_SOCKET", socket_path}],
        stderr_to_stdout: true
      )

    assert status == 2
    assert System.monotonic_time(:millisecond) - started_at < 500
    assert Jason.decode!(output)["error"] =~ "service unavailable"
  end
end
