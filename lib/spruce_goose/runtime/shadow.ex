defmodule SpruceGoose.Runtime.Shadow do
  @moduledoc "Provider-neutral import and parity boundary for runtime state envelopes."

  require Ash.Query

  alias SpruceGoose.{Authz, Repo}
  alias SpruceGoose.Runtime.ShadowSnapshot

  @envelope_fields [
    :protocol_version,
    :adapter,
    :external_id,
    :revision,
    :status,
    :checkpoint,
    :owner_context_digest,
    :state_digest,
    :wait_digest,
    :child_task_count
  ]

  def import(task, envelope) do
    attrs = Map.put(envelope, :task_id, task.id)

    # AUTHORIZATION: every read/create inside this transaction goes through
    # actor-scoped Authz; the raw transaction only binds lock and commit scope.
    case Repo.transaction(fn -> import_locked(attrs) end) do
      {:ok, {result, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parity(task, envelope) do
    case snapshot(envelope) do
      {:ok, nil} ->
        {:ok, identity(envelope) |> Map.merge(%{parity: false, missing: true, mismatches: []})}

      {:ok, snapshot} ->
        expected = Map.put(envelope, :task_id, task.id)
        mismatches = mismatches(snapshot, expected)

        {:ok,
         identity(envelope)
         |> Map.merge(%{parity: mismatches == [], missing: false, mismatches: mismatches})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_locked(attrs) do
    lock_key =
      "runtime-shadow:#{byte_size(attrs.adapter)}:#{attrs.adapter}:" <>
        "#{byte_size(attrs.external_id)}:#{attrs.external_id}:#{attrs.revision}"

    # AUTHORIZATION: this raw query acquires only a transaction-scoped lock;
    # all resource reads and writes below remain actor-authorized via Authz.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_key])

    case snapshot(attrs) do
      {:ok, nil} ->
        case Authz.create_with_notifications(ShadowSnapshot, attrs, action: :import) do
          {:ok, snapshot, notifications} -> {result(snapshot, true), notifications}
          {:error, reason} -> Repo.rollback(reason)
        end

      {:ok, snapshot} ->
        if mismatches(snapshot, attrs) == [] do
          {result(snapshot, false), []}
        else
          Repo.rollback("runtime revision conflicts with immutable snapshot")
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp snapshot(envelope) do
    ShadowSnapshot
    |> Ash.Query.filter_input(
      adapter: envelope.adapter,
      external_id: envelope.external_id,
      revision: envelope.revision
    )
    |> Authz.read()
    |> case do
      {:ok, []} -> {:ok, nil}
      {:ok, [snapshot]} -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mismatches(snapshot, expected) do
    [:task_id | @envelope_fields]
    |> Enum.filter(&(not equivalent?(&1, Map.get(snapshot, &1), Map.get(expected, &1))))
  end

  defp equivalent?(:status, left, right), do: to_string(left) == to_string(right)
  defp equivalent?(_field, left, right), do: left == right

  defp result(snapshot, created?) do
    identity(snapshot)
    |> Map.merge(%{created: created?, snapshot_id: snapshot.id})
  end

  defp identity(value) do
    %{
      adapter: value.adapter,
      external_id: value.external_id,
      revision: value.revision
    }
  end
end
