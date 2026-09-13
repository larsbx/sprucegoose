defmodule SpruceGoose.Workflows.Lifecycle do
  @moduledoc """
  Versioned, fail-closed task lifecycle contract.

  Every task is born in `inbox` and finishes in `completed` or `cancelled`,
  the only absorbing states. `failed` is not final: it re-enters `queued` for
  another attempt. `waiting` may resume straight into `in_progress`, through
  the same SOP gate as a fresh start; `blocked` must pass back through `ready`
  so that readiness is re-established.

  This module is only the relation. Preconditions that depend on data (the
  SOP gate, predecessor completion, artifact receipts, TODO completion, the
  reason a task waits or is cancelled) are enforced by the `Task` resource's
  `:transition` and `:move` actions.
  """

  use SpruceGoose.Lifecycle,
    version: 1,
    initial: :inbox,
    transitions: [
      inbox: [:proposed, :cancelled],
      proposed: [:queued, :cancelled],
      queued: [:ready, :blocked, :cancelled],
      ready: [:in_progress, :blocked, :cancelled],
      in_progress: [:waiting, :blocked, :completed, :failed, :cancelled],
      waiting: [:ready, :in_progress, :blocked, :cancelled],
      blocked: [:ready, :cancelled],
      completed: [],
      failed: [:queued, :cancelled],
      cancelled: []
    ]
end
