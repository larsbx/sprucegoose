defmodule SpruceGoose.CLI.SocketPlugTest do
  use ExUnit.Case, async: true

  setup do
    %{supervisor: start_supervised!(Task.Supervisor)}
  end

  defp call(args, supervisor, opts) do
    :post
    |> Plug.Test.conn("/v1/cli", Jason.encode!(%{args: args}))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> SpruceGoose.CLI.SocketPlug.call(
      SpruceGoose.CLI.SocketPlug.init(Keyword.put(opts, :supervisor, supervisor))
    )
  end

  test "executes a CLI request and preserves the JSON contract", %{supervisor: supervisor} do
    conn =
      call(["version"], supervisor, runner: fn ["version"] -> {:ok, %{version: "test"}} end)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"ok" => true, "version" => "test"}
  end

  test "rejects malformed and oversized argument lists before execution", %{
    supervisor: supervisor
  } do
    runner = fn _ -> flunk("invalid input reached the executor") end

    conn = call([123], supervisor, runner: runner)
    assert conn.status == 400

    conn = call(List.duplicate("arg", 129), supervisor, runner: runner)
    assert conn.status == 400
  end

  test "returns executor errors without crashing the connection", %{supervisor: supervisor} do
    conn = call(["not-a-command"], supervisor, runner: fn _ -> {:error, :usage} end)

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"] =~ "usage:"
  end

  test "times out a stalled request without waiting indefinitely", %{supervisor: supervisor} do
    started_at = System.monotonic_time(:millisecond)

    conn =
      call(["slow"], supervisor,
        runner: fn _ -> Process.sleep(:infinity) end,
        timeout: 30
      )

    assert conn.status == 504
    assert System.monotonic_time(:millisecond) - started_at < 250
    assert Jason.decode!(conn.resp_body) == %{"error" => "request timed out", "ok" => false}
  end

  test "a stalled request does not head-of-line block an independent request", %{
    supervisor: supervisor
  } do
    parent = self()

    runner = fn
      ["slow"] ->
        send(parent, :slow_started)
        Process.sleep(:infinity)

      ["fast"] ->
        {:ok, %{request: "fast"}}
    end

    slow = Task.async(fn -> call(["slow"], supervisor, runner: runner, timeout: 500) end)
    assert_receive :slow_started, 1_000

    fast = call(["fast"], supervisor, runner: runner, timeout: 500)
    assert fast.status == 200
    assert Jason.decode!(fast.resp_body) == %{"ok" => true, "request" => "fast"}

    assert Task.await(slow).status == 504
  end
end
