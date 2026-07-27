defmodule SpruceGoose.WorkflowDefinitionTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Workflows.Dag
  alias SpruceGoose.Workflows.Definition

  test "parses a versioned definition and produces a stable native execution order" do
    assert {:ok, definition} =
             Definition.parse(%{
               schema_version: 1,
               tasks: [
                 %{id: "publish", kind: :oban, depends_on: ["verify"]},
                 %{id: "capture", kind: :oban},
                 %{id: "verify", kind: :oban, depends_on: ["capture"]}
               ]
             })

    assert {:ok, ordered} = Dag.order(definition.tasks)
    assert Enum.map(ordered, & &1.id) == ["capture", "verify", "publish"]
  end

  test "rejects unsupported schema versions" do
    assert {:error, error} =
             Definition.parse(%{schema_version: 2, tasks: [%{id: "a", kind: :oban}]})

    assert Exception.message(error) =~ "must equal 1"
  end

  test "rejects duplicate task ids" do
    assert {:error, error} =
             Definition.parse(%{
               tasks: [%{id: "same", kind: :oban}, %{id: "same", kind: :oban}]
             })

    assert Exception.message(error) =~ "task ids must be unique"
  end

  test "rejects an execution kind outside the native allowlist" do
    assert {:error, error} =
             Definition.parse(%{tasks: [%{id: "a", kind: "arbitrary_shell"}]})

    assert Exception.message(error) =~ "Invalid value provided for kind"
  end

  test "rejects unknown, self, duplicate, and cyclic dependencies" do
    invalid_definitions = [
      {[%{id: "a", kind: :oban, depends_on: ["missing"]}], "unknown task"},
      {[%{id: "a", kind: :oban, depends_on: ["a"]}], "cannot depend on itself"},
      {[
         %{id: "a", kind: :oban},
         %{id: "b", kind: :oban, depends_on: ["a", "a"]}
       ], "duplicate dependencies"},
      {[
         %{id: "a", kind: :oban, depends_on: ["b"]},
         %{id: "b", kind: :oban, depends_on: ["a"]}
       ], "must be acyclic"}
    ]

    for {tasks, expected} <- invalid_definitions do
      assert {:error, error} = Definition.parse(%{tasks: tasks})
      assert Exception.message(error) =~ expected
    end
  end

  test "rejects an empty graph" do
    assert {:error, error} = Definition.parse(%{tasks: []})
    assert Exception.message(error) =~ "at least one task"
  end
end
