defmodule SpruceGoose.TaskFlow.Domain do
  use Ash.Domain

  authorization do
    authorize(:when_requested)
  end

  resources do
    resource(SpruceGoose.TaskFlow.ShadowSnapshot)
  end
end
