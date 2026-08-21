defmodule SpruceGoose.Actors.Role do
  @moduledoc """
  The capabilities a grant can confer, within its scope.

  Roles do not imply one another, with one exception encoded in
  `SpruceGoose.Actors.Scope`: every grant implies `:reader` within its own
  scope, because an operator that cannot read the task it is operating on is
  not a coherent grant.
  """

  use Ash.Type.Enum,
    values: [
      :reader,
      :operator,
      :derivation_executor,
      :artifact_verifier,
      :proposer,
      :approver,
      :author,
      :admin
    ]
end
