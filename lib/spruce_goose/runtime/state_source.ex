defmodule SpruceGoose.Runtime.StateSource do
  @moduledoc "Port implemented by replaceable runtime adapters at the system edge."

  @type envelope :: %{
          required(:protocol_version) => pos_integer(),
          required(:adapter) => String.t(),
          required(:external_id) => String.t(),
          required(:revision) => non_neg_integer(),
          required(:status) => String.t(),
          optional(:checkpoint) => String.t() | nil,
          required(:owner_context_digest) => String.t(),
          required(:state_digest) => String.t(),
          required(:wait_digest) => String.t(),
          required(:child_task_count) => non_neg_integer()
        }

  @callback snapshot(reference :: term()) :: {:ok, envelope()} | {:error, term()}
end
