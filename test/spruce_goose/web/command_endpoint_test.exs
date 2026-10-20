defmodule SpruceGoose.Web.CommandEndpointTest do
  @moduledoc """
  The authenticated write surface. A mutation reaches the system only as the
  actor bound to a verified OAuth client, and the ledger records that binding.
  """
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Kernel.Postgres.EventLedger

  @opts SpruceGoose.Web.Router.init([])

  test "an authenticated client runs commands as its bound actor and may not declare another" do
    {actor, token} = bound_client("cmd-whoami", [:reader])

    conn = post_commands(token, %{argv: ["whoami"]})
    assert conn.status == 200
    assert %{"ok" => true, "actor" => name} = Jason.decode!(conn.resp_body)
    assert name == actor.name

    conn = post_commands(token, %{argv: ["whoami", "--as", "someone-else"]})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] =~ "--as is not accepted"

    conn = post_commands(token, %{argv: []})
    assert conn.status == 400

    conn = post_commands(token, %{argv: ["no-such-noun"]})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] =~ "usage"

    conn = post_commands("not-a-token", %{argv: ["whoami"]})
    assert conn.status == 401
  end

  test "a mutation over the endpoint is certified with binding token; over the socket, declared" do
    {actor, token} = bound_client("cmd-mutate", [:reader, :operator, :proposer, :approver])
    task = task_fixture("endpoint")

    conn =
      post_commands(token, %{argv: ["task", "link", task.task_id, "evidence", "https://e/1"]})

    assert conn.status == 200, conn.resp_body

    assert {:ok, events} = EventLedger.read(EventLedger.new(), "authority:sprucegoose")
    event = List.last(events)
    assert event.payload["command"] == "link_task"
    assert event.payload["actor"] == %{"name" => actor.name, "binding" => "token"}

    assert {:ok, _} =
             Executor.run({:link_task, task.task_id, "evidence", "https://e/2"}, actor.name)

    assert {:ok, events} = EventLedger.read(EventLedger.new(), "authority:sprucegoose")
    assert List.last(events).payload["actor"] == %{"name" => actor.name, "binding" => "declared"}
  end

  test "declared resolution can be switched off, leaving only the authenticated path" do
    {actor, token} = bound_client("cmd-noname", [:reader])
    previous = Application.get_env(:spruce_goose, :declared_actor_resolution)
    on_exit(fn -> Application.put_env(:spruce_goose, :declared_actor_resolution, previous) end)
    Application.put_env(:spruce_goose, :declared_actor_resolution, false)

    assert {:error, message} = Executor.run(:whoami, actor.name)
    assert message =~ "disabled"
    assert post_commands(token, %{argv: ["whoami"]}).status == 200
  end

  defp post_commands(token, body) do
    :post
    |> Plug.Test.conn("/commands", Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> SpruceGoose.Web.Router.call(@opts)
  end

  defp bound_client(name, roles) do
    actor = Ash.create!(Actor, %{name: name, kind: :agent, created_by: "test"}, authorize?: false)

    for role <- roles,
        do:
          Ash.create!(Grant, %{actor_id: actor.id, role: role, scope: "*", granted_by: "test"},
            authorize?: false
          )

    user_id = Ecto.UUID.generate()
    {1, nil} = Repo.insert_all("users", [%{id: Ecto.UUID.dump!(user_id)}])
    client_id = Ecto.UUID.generate()

    previous = Application.get_env(:spruce_goose, :oauth_client_actor_bindings)
    Application.put_env(:spruce_goose, :oauth_client_actor_bindings, %{client_id => actor.id})

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:spruce_goose, :oauth_client_actor_bindings),
        else: Application.put_env(:spruce_goose, :oauth_client_actor_bindings, previous)
    end)

    {:ok, token, _claims} =
      AshAuthentication.Oauth2Server.Jwt.mint(SpruceGoose.Oauth2Server,
        sub: user_id,
        client_id: client_id,
        scope: "mcp"
      )

    {actor, token}
  end

  defp task_fixture(prefix) do
    suffix = "#{prefix}-#{System.unique_integer([:positive])}"
    project = Ash.create!(SpruceGoose.Workflows.Project, %{key: "cmd-#{suffix}", name: "Cmd"})

    roadmap =
      Ash.create!(SpruceGoose.Workflows.Roadmap, %{
        project_id: project.id,
        key: "cmd-#{suffix}",
        name: "Cmd"
      })

    workflow =
      Ash.create!(SpruceGoose.Workflows.Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "cmd-#{suffix}",
        name: "Cmd",
        definition: %{
          schema_version: 1,
          tasks: [%{id: "work", kind: :openclaw, depends_on: [], input: %{}}]
        }
      })

    Ash.create!(SpruceGoose.Workflows.Task, %{
      workflow_id: workflow.id,
      task_id: SpruceGoose.TaskId.generate(),
      task_type: :task,
      title: "Cmd task",
      definition_of_done: "Linked.",
      runner: :openclaw
    })
  end
end
