defmodule SpruceGoose.Web.McpAuthTest do
  @moduledoc """
  Fail-closed contract for the MCP surface.

  SpruceGoose is the authoritative task substrate, so the MCP tool surface must
  never be reachable without a valid OAuth bearer token. These tests exercise
  the router pipeline directly rather than a live socket, so they run in CI
  without binding a port.
  """
  use SpruceGoose.DataCase, async: false

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

  describe "OAuth client to actor binding" do
    test "a caller-controlled OAuth client assign cannot impersonate an actor" do
      actor = mcp_actor("mcp-name-spoof")
      client_id = Ecto.UUID.generate()
      restore_bindings(%{client_id => actor.id})

      conn =
        :get
        |> Plug.Test.conn("/")
        |> Plug.Conn.assign(:oauth2_client, %{id: client_id, client_name: actor.name})
        |> SpruceGoose.Web.ActorPlug.call([])

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body =~ "verified OAuth client ID"
    end

    test "a real bearer token resolves verified client_id, not OAuth user sub" do
      {conn, actor, user_id, client_id} = real_bearer_call("mcp-real-client", "mcp")

      assert user_id != client_id
      assert conn.status == 200
      refute conn.halted
      assert Ash.PlugHelpers.get_actor(conn).id == actor.id
    end

    test "real bearer tokens without the exact mcp scope fail insufficient_scope" do
      actor = mcp_actor("mcp-scope-gate")
      user_id = seed_oauth_user()
      client_id = Ecto.UUID.generate()
      restore_bindings(%{client_id => actor.id})

      for scope <- ["", "other"] do
        conn = minted_mcp_call(user_id, client_id, scope)
        assert conn.status == 403
        assert conn.halted

        challenge = conn |> Plug.Conn.get_resp_header("www-authenticate") |> List.first()
        assert challenge =~ ~s(error="insufficient_scope")
        assert challenge =~ ~s(scope="mcp")
      end
    end
  end

  describe "tool surface" do
    test "exposes only read actions, and only to an actor" do
      assert AshAi.exposed_tools(otp_app: :spruce_goose) == []

      tools = AshAi.exposed_tools(otp_app: :spruce_goose, actor: mcp_actor("mcp-reader"))

      assert tools != []

      for tool <- tools do
        assert tool.action.type == :read,
               "tool #{inspect(tool.name)} exposes a #{tool.action.type} action; " <>
                 "the MCP surface is intentionally read-only"
      end
    end
  end

  defp real_bearer_call(actor_name, scope) do
    actor = mcp_actor(actor_name)
    user_id = seed_oauth_user()
    client_id = Ecto.UUID.generate()
    restore_bindings(%{client_id => actor.id})
    {minted_mcp_call(user_id, client_id, scope), actor, user_id, client_id}
  end

  defp seed_oauth_user do
    user_id = Ecto.UUID.generate()
    {1, nil} = SpruceGoose.Repo.insert_all("users", [%{id: Ecto.UUID.dump!(user_id)}])
    user_id
  end

  defp minted_mcp_call(user_id, client_id, scope) do
    {:ok, token, claims} =
      AshAuthentication.Oauth2Server.Jwt.mint(SpruceGoose.Oauth2Server,
        sub: user_id,
        client_id: client_id,
        scope: scope
      )

    assert claims["sub"] == user_id
    assert claims["client_id"] == client_id
    mcp_call([{"authorization", "Bearer #{token}"}])
  end

  defp restore_bindings(bindings) do
    previous = Application.get_env(:spruce_goose, :oauth_client_actor_bindings)
    Application.put_env(:spruce_goose, :oauth_client_actor_bindings, bindings)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:spruce_goose, :oauth_client_actor_bindings)
      else
        Application.put_env(:spruce_goose, :oauth_client_actor_bindings, previous)
      end
    end)
  end

  defp mcp_actor(name) do
    {:ok, actor} =
      Ash.create(
        SpruceGoose.Actors.Actor,
        %{name: name, kind: :agent, created_by: "mcp-auth-test"},
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
