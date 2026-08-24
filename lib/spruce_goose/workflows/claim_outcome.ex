defmodule SpruceGoose.Workflows.ClaimOutcome do
  @moduledoc """
  The verdict an external runner returns for a completion claim.

  `:unverified` is the initial state and is deliberately distinct from
  `:confirmed`: a claim nobody probed is not a claim that passed. That
  distinction is the whole point of the detection — silence must not read as
  success.
  """
  use Ash.Type.Enum,
    values: [
      :unverified,
      :confirmed,
      :refuted,
      :unreachable
    ]
end
