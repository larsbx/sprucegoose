defmodule SpruceGoose.AgentHooks do
  @moduledoc "Read and review durable agent runs and inbox recommendations."
  use Ash.Domain

  authorization do
    authorize(:by_default)
  end

  resources do
    resource(SpruceGoose.AgentHooks.Run)
    resource(SpruceGoose.AgentHooks.TriageResult)
  end
end
