defmodule SpruceGoose.Deployment.Operation do
  @moduledoc """
  Pure execution-evidence contract for a previously authorized operation.

  Request, start, timeout, and observed completion are distinct. A timeout leaves
  the outcome unknown and requires inspection; it is never permission to issue
  the host command again. Identical receipts are idempotent; conflicting ones
  fail closed. A receipt binds the operation, deployment, and desired artifact.

  This module neither authorizes nor persists anything. The future admission
  transaction must bind the operation ID to the entire immutable request and
  queue it atomically with consumed authorization. Only authenticated adapter
  observations may be passed to `observe/3`; a caller-supplied map is not proof.
  """

  alias SpruceGoose.Deployment.Artifact

  @enforce_keys [:operation_id, :deployment_id, :action, :artifact, :requested_at]
  defstruct @enforce_keys ++ [state: :requested, started_at: nil, receipt: nil]

  def request(operation_id, deployment_id, action, artifact, now \\ DateTime.utc_now())

  def request(operation_id, deployment_id, action, %Artifact{} = artifact, %DateTime{} = now)
      when action in [:deploy, :rollback] do
    if present?(operation_id) and present?(deployment_id) and Artifact.valid?(artifact) do
      {:ok,
       %__MODULE__{
         operation_id: operation_id,
         deployment_id: deployment_id,
         action: action,
         artifact: artifact,
         requested_at: now
       }}
    else
      {:error, :invalid_operation}
    end
  end

  def request(_, _, _, _, _), do: {:error, :invalid_operation}

  def start(operation, now \\ DateTime.utc_now())

  def start(%__MODULE__{state: :requested} = operation, %DateTime{} = now) do
    if DateTime.compare(now, operation.requested_at) != :lt,
      do: {:ok, %{operation | state: :started, started_at: now}},
      else: {:error, :invalid_operation_time}
  end

  def start(_, _), do: {:error, :inspection_required}

  def timeout(%__MODULE__{state: state} = operation) when state in [:started, :unknown],
    do: {:ok, %{operation | state: :unknown}}

  def timeout(_), do: {:error, :invalid_operation_state}

  def observe(operation, receipt, now \\ DateTime.utc_now())

  def observe(
        %__MODULE__{state: :observed_completed, receipt: receipt} = operation,
        receipt,
        %DateTime{}
      ),
      do: {:ok, operation}

  def observe(%__MODULE__{state: :observed_completed}, _, _),
    do: {:error, :conflicting_receipt}

  def observe(%__MODULE__{state: state} = operation, %{} = receipt, %DateTime{} = now)
      when state in [:started, :unknown] do
    with %{
           operation_id: id,
           deployment_id: deployment_id,
           action: action,
           artifact: artifact,
           observed_at: %DateTime{} = at,
           status: :succeeded,
           evidence_digest: digest
         } <- receipt,
         true <- id == operation.operation_id and deployment_id == operation.deployment_id,
         true <- action == operation.action and artifact == operation.artifact,
         true <- is_binary(digest) and Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, digest),
         true <- DateTime.compare(at, operation.started_at) != :lt,
         age <- DateTime.diff(now, at, :microsecond),
         true <- age >= 0 and age <= 900_000_000 do
      {:ok, %{operation | state: :observed_completed, receipt: receipt}}
    else
      _ -> {:error, :invalid_completion_receipt}
    end
  end

  def observe(_, _, _), do: {:error, :invalid_completion_receipt}

  @doc "New events never describe a request as an executed host operation."
  def event_type(%__MODULE__{action: action, state: state})
      when action in [:deploy, :rollback] and
             state in [:requested, :started, :unknown, :observed_completed],
      do: Atom.to_string(action) <> "_" <> Atom.to_string(state)

  @doc "Legacy executed events are historical requests, never completion proof."
  def legacy_evidence_class(event)
      when event in ["deploy_executed", "rollback_executed", "reclaim_executed"],
      do: :request_only

  def legacy_evidence_class(_), do: :unclassified

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
