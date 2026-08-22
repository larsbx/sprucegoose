defmodule SpruceGoose.Runtime.Domain do
  use Ash.Domain

  authorization do
    authorize(:when_requested)
  end

  resources do
    resource(SpruceGoose.Runtime.ShadowSnapshot)
  end
end
