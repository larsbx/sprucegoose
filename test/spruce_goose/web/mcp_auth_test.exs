defmodule SpruceGoose.Web.McpAuthTest do
  @moduledoc """
  Fail-closed contract for the MCP surface.

  SpruceGoose is the authoritative task substrate, so the MCP tool surface must
  never be reachable without a valid OAuth bearer token. These tests exercise
  the router pipeline directly rather than a live socket, so they run in CI
  without binding a port.
  """
  # DataCase rather than ExUnit.Case: the tool surface is now actor-scoped, so
  # asserting what it exposes means having an actor, and that means the sandbox.
  use SpruceGoose.DataCase, async: true

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
    test "exposes only read actions, and only to an actor" do
      # `AshAi.exposed_tools/1` ends in a `can?` filter, so with the Workflows
      # resources policy-protected an actor-less caller sees nothing at all.
      # That is the surface `SpruceGoose.Web.ActorPlug` exists to prevent
      # reaching: an unregistered client is refused, never treated as anonymous.
      assert AshAi.exposed_tools(otp_app: :spruce_goose) == []

      tools = AshAi.exposed_tools(otp_app: :spruce_goose, actor: mcp_actor())

      assert tools != []

      for tool <- tools do
        assert tool.action.type == :read,
               "tool #{inspect(tool.name)} exposes a #{tool.action.type} action; " <>
                 "the MCP surface is intentionally read-only"
      end
    end
  end

  defp mcp_actor do
    {:ok, actor} =
      Ash.create(
        SpruceGoose.Actors.Actor,
        %{name: "mcp-reader", kind: :agent, created_by: "mcp-auth-test"},
        authorize?: false
      )

    {:ok, _grant} =
      Ash.create(
        SpruceGoose.Actors.Grant,
        %{actor_id: actor.id, role: :reader, scope: "*", granted_by: "mcp-auth-test"},
        authorize?: false
      )

    actor
  end
end
