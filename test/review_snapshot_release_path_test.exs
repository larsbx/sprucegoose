defmodule SpruceGoose.ReviewSnapshotReleasePathTest do
  use ExUnit.Case, async: false

  @moduletag :separate_sessions
  @moduletag skip: System.get_env("SG_COMMIT", "development") == "development"

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Repo
  alias SpruceGoose.Workflows.{Definition, Project, Roadmap, Task, Workflow}

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    SpruceGoose.DataCase.seed_system_actor()
    :ok
  end

  test "release identity establishes repeatable-read read-only snapshot before canonical reads" do
    commit = System.fetch_env!("SG_COMMIT")
    tree = System.fetch_env!("SG_TREE")
    assert commit =~ ~r/^[0-9a-f]{40}$/
    assert tree =~ ~r/^[0-9a-f]{40}$/

    {:ok, definition} = Definition.parse(%{tasks: [%{id: "admit", kind: :oban}]})

    project =
      Ash.create!(Project, %{key: "release-review", name: "Release Review"}, authorize?: false)

    roadmap =
      Ash.create!(
        Roadmap,
        %{project_id: project.id, key: "snapshot", name: "Snapshot"},
        authorize?: false
      )

    workflow =
      Ash.create!(
        Workflow,
        %{
          roadmap_id: roadmap.id,
          workflow_id: "release-review-snapshot",
          name: "Release Review Snapshot",
          definition: definition
        },
        authorize?: false
      )

    Ash.create!(
      Task,
      %{
        task_id: SpruceGoose.TaskId.generate(),
        title: "Release snapshot row",
        workflow_id: workflow.id,
        definition_of_done: "Snapshot returns the row",
        runner: :oban,
        priority: 1
      },
      authorize?: false
    )

    SpruceGoose.Identity.Local.peer_id()

    assert {:ok, envelope} = Executor.run(:review_task_snapshot)
    payload = envelope.receipt.payload |> Base.decode64!() |> Jason.decode!()

    assert payload["schema"] == "sprucegoose-review-snapshot-v1"
    assert payload["snapshot"]["isolation"] == "repeatable read"

    assert payload["source"] == %{
             "commit" => commit,
             "module_md5" => payload["source"]["module_md5"],
             "tree" => tree
           }

    assert payload["total"] == 1
    assert payload["count"] == 1
    assert [%{"title" => "Release snapshot row"}] = payload["tasks"]
  end
end
