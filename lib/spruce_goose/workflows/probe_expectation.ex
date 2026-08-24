defmodule SpruceGoose.Workflows.ProbeExpectation do
  @moduledoc """
  What result counts as the claim holding true.

  Stated explicitly because the two motivating failures needed opposite
  polarities: the secrets-custody claim expected a file to be present
  (`:exit_zero`), while the Woodpecker retirement expected `is-enabled` to
  *fail* (`:exit_nonzero`). Recording the expectation alongside the probe
  keeps that polarity in the data rather than in a runner's assumptions.
  """
  use Ash.Type.Enum,
    values: [
      :exit_zero,
      :exit_nonzero
    ]
end
