defmodule Orchestrator.Workflows.Definition do
  use Ash.Resource, data_layer: :embedded

  alias Orchestrator.Workflows.Dag
  alias Orchestrator.Workflows.TaskDefinition

  attributes do
    attribute(:schema_version, :integer,
      allow_nil?: false,
      default: 1,
      public?: true
    )

    attribute(:tasks, {:array, TaskDefinition}, allow_nil?: false, public?: true)
  end

  actions do
    default_accept(:*)
    defaults([:read, create: :*])
  end

  validations do
    validate(attribute_equals(:schema_version, 1))

    validate(fn changeset, _context ->
      changeset
      |> Ash.Changeset.get_attribute(:tasks)
      |> Dag.validate()
      |> case do
        :ok -> :ok
        {:error, message} -> {:error, field: :tasks, message: message}
      end
    end)
  end

  def parse(input), do: Ash.create(__MODULE__, input)
end
