defmodule SpruceGoose.Evidence.Snapshot do
  @moduledoc """
  Transaction-bound authority evidence snapshot.

  ## Why the isolation guard exists

  A disposable-cluster spike (transcript `e0babbda…`) established that on
  ecto 3.14.2 / ecto_sql 3.14.0 / postgrex 0.22.4, passing
  `Repo.transaction(fun, isolation: :repeatable_read)` is **accepted and
  inert**: it raises nothing and the transaction still runs at
  `read committed`. A control call without the option produced byte-identical
  output, which is what proves inertness rather than mere non-verification.

  Change A therefore issues `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ,
  READ ONLY` as the first statement of the callback and then verifies the
  **observed** values. The recorded payload carries what PostgreSQL reported,
  never what was requested.
  """

  @required_isolation "repeatable read"
  @required_read_only "on"

  @set_transaction "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY"

  @doc "The exact first statement of the snapshot transaction."
  def set_transaction_sql, do: @set_transaction

  @doc """
  Issue the mode statement and verify observed values.

  `exec` is a 2-arity `(sql, params)` callback returning `{:ok, rows}` or
  `{:error, reason}`, so the guard is testable without a database.

  A failed `SHOW` is `:transaction_mode_unknown`, never a pass: an instrument
  that cannot report is not evidence of correctness.
  """
  def verify_transaction_mode(exec) when is_function(exec, 2) do
    _ = exec.(@set_transaction, [])

    with {:ok, isolation} <- show(exec, "SHOW transaction_isolation"),
         {:ok, read_only} <- show(exec, "SHOW transaction_read_only") do
      observed = %{isolation: isolation, read_only: read_only}

      if isolation == @required_isolation and read_only == @required_read_only do
        :ok
      else
        {:error, {:transaction_mode_refused, observed}}
      end
    end
  end

  defp show(exec, sql) do
    case exec.(sql, []) do
      {:ok, [[value]]} when is_binary(value) -> {:ok, value}
      {:ok, other} -> {:error, {:transaction_mode_unknown, {sql, other}}}
      {:error, reason} -> {:error, {:transaction_mode_unknown, {sql, reason}}}
    end
  end

  @doc """
  Require the visibility snapshot to be unchanged across every page.

  Drift means the reads did not share one snapshot, so the completeness claim
  would be false.
  """
  def verify_snapshot_stability(first, last)

  def verify_snapshot_stability(same, same), do: :ok
  def verify_snapshot_stability(first, last), do: {:error, {:snapshot_drift, first, last}}
end
