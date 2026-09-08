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

  test "a stale managed Unix socket is reclaimed on restart" do
    socket_path = Path.join(owner_only_dir(), "restartable-sprucegoose.sock")

    request_supervisor = start_supervised!(Task.Supervisor)

    runner = fn
      ["version"] -> {:ok, %{version: "restart-test"}}
      _ -> {:error, "unexpected command"}
    end

    children = [
      {SpruceGoose.CLI.SocketPath, socket_path},
      {Bandit,
       plug:
         {SpruceGoose.CLI.SocketPlug,
          runner: runner, supervisor: request_supervisor, timeout: 100},
       scheme: :http,
       ip: {:local, socket_path},
       port: 0,
       startup_log: false}
    ]

    {:ok, service} = Supervisor.start_link(children, strategy: :one_for_one)
    assert eventually(fn -> File.exists?(socket_path) end)
    :ok = Supervisor.stop(service)
    assert File.exists?(socket_path)

    {:ok, restarted} = Supervisor.start_link(children, strategy: :one_for_one)
    assert eventually(fn -> File.exists?(socket_path) end)
    :ok = Supervisor.stop(restarted)
    assert :ok = SpruceGoose.CLI.SocketPath.remove(socket_path)
    refute File.exists?(socket_path)
  end

  describe "socket directory boundary" do
    test "an owner-only directory is accepted" do
      assert :ok = SpruceGoose.CLI.SocketPath.verify_directory(owner_only_dir())
    end

    test "a group- or world-reachable directory is refused" do
      # This is the shape /tmp itself has, and the shape this test file used to
      # bind its sockets into. The socket is the whole authentication boundary,
      # so a directory anyone can traverse is not a configuration to accept
      # quietly.
      dir = owner_only_dir()
      File.chmod!(dir, 0o755)

      assert {:error, message} = SpruceGoose.CLI.SocketPath.verify_directory(dir)
      assert message =~ "is mode 0755"
      assert message =~ "owner-only"
    end

    test "a missing directory is refused rather than created" do
      dir = Path.join(owner_only_dir(), "absent")

      assert {:error, message} = SpruceGoose.CLI.SocketPath.verify_directory(dir)
      assert message =~ "cannot inspect CLI socket directory"
    end

    test "the service refuses to start on a world-reachable directory" do
      dir = owner_only_dir()
      File.chmod!(dir, 0o777)

      assert {:error, message} =
               SpruceGoose.CLI.SocketPath.start_link(Path.join(dir, "cli.sock"))

      assert message =~ "owner-only"
    end
  end

  defp owner_only_dir do
    dir =
      Path.join(System.tmp_dir!(), "sprucegoose-socket-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts),
    do:
      fun.() or
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
end
