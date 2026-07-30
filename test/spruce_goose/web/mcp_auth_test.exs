defmodule SpruceGoose.Web.McpAuthTest do
  @moduledoc """
  Fail-closed contract for the MCP surface.

  SpruceGoose is the authoritative task substrate, so the MCP tool surface must
  never be reachable without a valid OAuth bearer token. These tests exercise
  the router pipeline directly rather than a live socket, so they run in CI
  without binding a port.
  """
  use ExUnit.Case, async: true

  @opts SpruceGoose.Web.Router.init([])

  defp mcp_call(headers) do
    body = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"})

    :post
    |> Plug.Test.conn("/mcp", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
    end)
    |> SpruceGoose.Web.Router.call(@opts)
  end

  describe "MCP endpoint authorization" do
    test "rejects a request with no Authorization header" do
      conn = mcp_call([])
      assert conn.status == 401
    end

    test "rejects a malformed bearer token" do
      conn = mcp_call([{"authorization", "Bearer not-a-real-token"}])
      assert conn.status == 401
    end

    test "rejects a non-bearer Authorization scheme" do
      conn = mcp_call([{"authorization", "Basic dXNlcjpwYXNz"}])
      assert conn.status == 401
    end

    test "advertises the protected-resource metadata and scope on rejection" do
      conn = mcp_call([])

      challenge =
        conn
        |> Plug.Conn.get_resp_header("www-authenticate")
        |> List.first()

      assert challenge =~ "Bearer"
      assert challenge =~ "resource_metadata="
      assert challenge =~ ~s(scope="mcp")
    end

    test "does not leak tool names to an unauthenticated caller" do
      conn = mcp_call([])

      refute conn.resp_body =~ "list_tasks"
      refute conn.resp_body =~ "list_projects"
    end
  end

  describe "tool surface" do
    test "exposes only read actions" do
      tools = AshAi.exposed_tools(otp_app: :spruce_goose)

      assert tools != []

      for tool <- tools do
        assert tool.action.type == :read,
               "tool #{inspect(tool.name)} exposes a #{tool.action.type} action; " <>
                 "the MCP surface is intentionally read-only"
      end
    end
  end
end
