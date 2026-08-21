defmodule SpruceGoose.LegibilityTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Workflows.{Definition, Project, Roadmap, Task, Workflow}

  test "project view renders stable read-only machine, Markdown, and DOT projections" do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "view", kind: :oban}]})
    project = Ash.create!(Project, %{key: "legibility-view", name: "Legibility View"})

    roadmap =
      Ash.create!(Roadmap, %{project_id: project.id, key: "delivery", name: "Delivery"})

    workflow =
      Ash.create!(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "delivery-v1",
        name: "Delivery v1",
        definition: definition
      })

    task =
      Ash.create!(Task, %{
        workflow_id: workflow.id,
        task_id: SpruceGoose.TaskId.generate(),
        title: "Visible task",
        definition_of_done: "The task is legible",
        priority: 3,
        runner: :oban
      })

    assert {:ok, view} = Executor.run({:view_project, "legibility-view"})
    assert view.snapshot.project.key == "legibility-view"

    assert get_in(view.snapshot, [:roadmaps, Access.at(0), :workflows, Access.at(0), :tasks]) == [
             %{
               id: task.task_id,
               title: "Visible task",
               type: :task,
               state: :inbox,
               priority: 3,
               definition_of_done: "The task is legible"
             }
           ]

    assert view.markdown =~ "Generated read-only from SpruceGoose/Ash authority"
    assert view.markdown =~ task.task_id
    assert view.dot =~ ~s("#{task.task_id}")
  end
end
