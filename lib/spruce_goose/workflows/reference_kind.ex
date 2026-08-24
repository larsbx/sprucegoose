defmodule SpruceGoose.Workflows.ReferenceKind do
  @moduledoc """
  The kinds of evidence a task can carry.

  These are the values `sprucegoose task link ID KIND VALUE` has always
  accepted; naming them as a type makes the set explicit and lets the
  precondition detection distinguish proof (`finding`, `regression`) from
  mere context (`sop`, `session`, `repo`, `flow`, `cron`).
  """
  use Ash.Type.Enum,
    values: [
      :finding,
      :regression,
      :sop,
      :flow,
      :cron,
      :session,
      :repo
    ]

  @proof [:finding, :regression]

  @doc "Kinds that constitute verification, as opposed to context."
  def proof_kinds, do: @proof
end
