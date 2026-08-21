defmodule SpruceGoose.OrchestrationDslTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Workflows

  test "the Ash domain exposes the complete orchestration hierarchy" do
    assert MapSet.new(Ash.Domain.Info.resources(Workflows)) ==
             MapSet.new([
               Workflows.Project,
               Workflows.Roadmap,
               Workflows.Workflow,
               Workflows.Board,
               Workflows.BoardColumn,
               Workflows.SavedFilter,
               Workflows.Task,
               Workflows.Dependency,
               Workflows.Todo,
               Workflows.TodoDependency,
               Workflows.InboxItem,
               Workflows.Revision,
               Workflows.BlueprintRevision
             ])
  end

  test "every child level has explicit parentage and stable identity" do
    assert relationship(Workflows.Roadmap, :project).allow_nil? == false
    assert relationship(Workflows.Workflow, :roadmap).allow_nil? == false
    assert relationship(Workflows.Task, :workflow).allow_nil? == false
    assert relationship(Workflows.Todo, :task).allow_nil? == false

    assert identity_fields(Workflows.Project, :unique_project_key) == [:key]

    assert identity_fields(Workflows.Roadmap, :unique_roadmap_key_per_project) ==
             [:project_id, :key]

    assert identity_fields(Workflows.Workflow, :unique_workflow_id_per_roadmap) ==
             [:roadmap_id, :workflow_id]

    assert identity_fields(Workflows.Task, :stable_task_id) == [:task_id]
    assert identity_fields(Workflows.Todo, :stable_todo_per_task) == [:task_id, :todo_id]
  end

  test "tasks carry authority fields and TODOs remain subordinate checklist state" do
    task_attributes = attribute_names(Workflows.Task)
    todo_attributes = attribute_names(Workflows.Todo)

    for field <- [:task_id, :definition_of_done, :state, :runner, :input, :lock_version] do
      assert field in task_attributes
    end

    assert :completed in todo_attributes
    refute :state in todo_attributes
    refute :runner in todo_attributes
  end

  test "dependency edges are unique and reject self-reference in Postgres" do
    assert identity_fields(Workflows.Dependency, :unique_dependency) ==
             [:predecessor_id, :successor_id]

    constraint =
      Workflows.Dependency
      |> AshPostgres.DataLayer.Info.check_constraints()
      |> Enum.find(&(&1.name == "not_self_dependency"))

    assert constraint.check == "predecessor_id <> successor_id"
  end

  test "task lifecycle is an explicit Ash action over a fail-closed transition table" do
    assert Ash.Resource.Info.action(Workflows.Task, :transition)
    assert Workflows.Lifecycle.allowed?(:queued, :ready)
    assert Workflows.Lifecycle.allowed?(:in_progress, :completed)
    refute Workflows.Lifecycle.allowed?(:queued, :completed)
    refute Workflows.Lifecycle.allowed?(:completed, :queued)
  end

  defp relationship(resource, name), do: Ash.Resource.Info.relationship(resource, name)

  defp identity_fields(resource, name) do
    resource
    |> Ash.Resource.Info.identity(name)
    |> Map.fetch!(:keys)
  end

  defp attribute_names(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(& &1.name)
  end
end
