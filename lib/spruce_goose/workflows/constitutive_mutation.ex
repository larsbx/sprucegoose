defmodule SpruceGoose.Workflows.ConstitutiveMutation do
  @moduledoc false

  @message "constitutive mutations require an exact verified repository blueprint"

  def validate_legacy do
    if Application.get_env(:spruce_goose, :allow_legacy_hierarchy_mutation, false) do
      :ok
    else
      {:error, @message}
    end
  end

  def refusal_message, do: @message
end
