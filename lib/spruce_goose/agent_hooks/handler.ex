defmodule SpruceGoose.AgentHooks.Handler do
  @moduledoc """
  Adapter for one bounded, read-only inbox triage computation.

  `propose/1` receives the frozen run context, including the charter. Return a
  string-keyed proposal accepted by `Proposal.validate/1`, or `{:error, reason}`.
  It runs outside a database transaction, with no Authz actor in scope. Adapters
  are trusted application code: this callback is not a sandbox for BEAM code.
  Remote agents should receive only this context and return data, never commands.
  """

  @callback propose(map()) :: {:ok, map()} | {:error, term()}
end
