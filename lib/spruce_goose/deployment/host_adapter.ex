defmodule SpruceGoose.Deployment.HostAdapter do
  @moduledoc """
  The bounded boundary between the deployment domain and a host.

  An adapter performs exactly the operation it is handed, identified by a
  stable `operation_id` it must use for duplicate detection on the host, and
  answers inspection questions about that operation. It receives no command,
  no shell, and no caller-supplied path: the request carries only identities.

  Adapters are expected to be small and separately runnable, so the host can
  still restart or roll back SpruceGoose when SpruceGoose itself is down.
  """

  @type request :: %{
          operation_id: String.t(),
          action: :execute_deploy | :execute_rollback | :execute_reclaim,
          deployment_id: String.t(),
          environment: atom(),
          release: map(),
          target: %{deployment_id: String.t(), release: map()} | nil
        }

  @type receipt :: %{
          optional(:evidence_digest) => String.t() | nil,
          optional(:detail) => String.t() | nil
        }
  @type observation :: %{
          optional(:detail) => String.t() | nil,
          status: :succeeded | :failed | :in_progress | :unknown
        }

  @doc "Perform the operation once. Must be idempotent per `operation_id`."
  @callback execute(request()) :: {:ok, receipt()} | {:error, term()}

  @doc "Inspect the host for the outcome of a previously started operation."
  @callback observe(request()) :: {:ok, observation()} | {:error, term()}
end
