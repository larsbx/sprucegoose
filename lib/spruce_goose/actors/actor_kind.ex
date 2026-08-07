defmodule SpruceGoose.Actors.ActorKind do
  @moduledoc """
  What sort of thing is acting.

  `:agent` is not cosmetic — it is the discriminator the self-approval rule
  turns on. A human may sign off on their own proposal; an agent never may.
  `:system` is reserved for internal callers (ledger import, outbox dispatch)
  that act with no human behind them.
  """

  use Ash.Type.Enum, values: [:human, :agent, :system]
end
