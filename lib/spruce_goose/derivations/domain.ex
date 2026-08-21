defmodule SpruceGoose.Derivations.Domain do
  @moduledoc "Typed authority for deterministic source derivations."

  use Ash.Domain

  authorization do
    authorize(:when_requested)
  end

  resources do
    resource(SpruceGoose.Derivations.Permit)
  end
end
