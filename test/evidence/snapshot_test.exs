defmodule SpruceGoose.Evidence.SnapshotTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Evidence.Snapshot

  # A fake SQL executor lets the observed-value guard be tested without a
  # database. The guard is the load-bearing control: the spike proved Ecto's
  # `isolation:` option is accepted but inert, so only the OBSERVED values may
  # be trusted.
  defp exec_returning(map) do
    fn sql, _params ->
      cond do
        String.starts_with?(sql, "SET TRANSACTION") -> {:ok, :set}
        sql == "SHOW transaction_isolation" -> {:ok, [[map.isolation]]}
        sql == "SHOW transaction_read_only" -> {:ok, [[map.read_only]]}
        true -> {:ok, [[nil]]}
      end
    end
  end

  describe "observed-value isolation guard" do
    test "accepts only repeatable read + on" do
      exec = exec_returning(%{isolation: "repeatable read", read_only: "on"})
      assert :ok = Snapshot.verify_transaction_mode(exec)
    end

    test "refuses when isolation is read committed (the inert-option failure)" do
      exec = exec_returning(%{isolation: "read committed", read_only: "on"})

      assert {:error, {:transaction_mode_refused, observed}} =
               Snapshot.verify_transaction_mode(exec)

      assert observed.isolation == "read committed"
    end

    test "refuses when access mode is not read only" do
      exec = exec_returning(%{isolation: "repeatable read", read_only: "off"})

      assert {:error, {:transaction_mode_refused, observed}} =
               Snapshot.verify_transaction_mode(exec)

      assert observed.read_only == "off"
    end

    test "refuses when the SET TRANSACTION statement was never issued" do
      # No SET issued: server defaults leak through and the guard must catch it.
      exec = fn
        "SHOW transaction_isolation", _ -> {:ok, [["read committed"]]}
        "SHOW transaction_read_only", _ -> {:ok, [["off"]]}
        _, _ -> {:ok, [[nil]]}
      end

      assert {:error, {:transaction_mode_refused, _}} = Snapshot.verify_transaction_mode(exec)
    end

    test "a SHOW failure is a refusal, never a pass" do
      exec = fn _, _ -> {:error, :boom} end
      assert {:error, {:transaction_mode_unknown, _}} = Snapshot.verify_transaction_mode(exec)
    end
  end

  describe "snapshot identifier stability" do
    test "identical first/last identifiers pass" do
      assert :ok = Snapshot.verify_snapshot_stability("709:709:", "709:709:")
    end

    test "drifted identifiers are a typed refusal" do
      assert {:error, {:snapshot_drift, "709:709:", "710:710:"}} =
               Snapshot.verify_snapshot_stability("709:709:", "710:710:")
    end
  end

  describe "call-graph prohibition" do
    test "evidence modules never reference peer_id/0" do
      for f <- Path.wildcard("lib/spruce_goose/evidence/*.ex") do
        refute File.read!(f) =~ "peer_id", "#{f} must not call peer_id/0"
      end
    end

    test "evidence modules never query peer_private_key directly" do
      for f <- Path.wildcard("lib/spruce_goose/evidence/*.ex") do
        refute File.read!(f) =~ "peer_private_key", "#{f} must not read the private half"
      end
    end
  end
end
