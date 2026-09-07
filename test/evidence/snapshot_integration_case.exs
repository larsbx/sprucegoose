defmodule SpruceGoose.Evidence.SnapshotIntegrationTest do
  @moduledoc """
  Non-sandbox lane. Requires a disposable PostgreSQL cluster supplied by the
  integration runner; never the authority database. Proves the amended
  transaction contract end to end.

  The spike (transcript e0babbda…) proved Ecto's `isolation:` option is
  accepted but INERT on ecto 3.14.2 / ecto_sql 3.14.0 / postgrex 0.22.4, so
  only the explicit first-statement mechanism plus observed-value verification
  is permitted.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias SpruceGoose.Evidence.Snapshot

  test "P1 control: a writable transaction commits and is visible elsewhere" do
    assert {:ok, :control_write_ok} = Snapshot.Test.Support.writable_control()
  end

  test "P2 control: READ COMMITTED observes a concurrent commit" do
    assert {:ok, %{before: b, after: a}} = Snapshot.Test.Support.read_committed_control()
    assert a == b + 1, "harness cannot observe visibility changes; results uninterpretable"
  end

  test "1. explicit first statement establishes the mode" do
    assert {:ok, obs} = Snapshot.Test.Support.observed_mode()
    assert obs.isolation == "repeatable read"
    assert obs.read_only == "on"
  end

  test "3. PostgreSQL rejects a persistent write with SQLSTATE 25006" do
    assert {:error, :read_only_sql_transaction} = Snapshot.Test.Support.attempt_write()
  end

  test "4/6. concurrent commits invisible across pages; snapshot ids identical" do
    assert {:ok, r} = Snapshot.Test.Support.paged_with_concurrent_commit()
    assert r.sees_concurrent == 0
    assert r.snap_first == r.snap_last
    assert r.page1 == r.page2
  end

  test "5. a fresh transaction sees the committed row" do
    assert {:ok, 1} = Snapshot.Test.Support.fresh_sees_committed()
  end

  test "7. omitting SET TRANSACTION makes the observed-value guard refuse" do
    assert {:error, {:transaction_mode_refused, obs}} = Snapshot.Test.Support.without_set_transaction()
    assert obs.isolation == "read committed"
  end

  test "Change A never relies on the Ecto isolation option" do
    for f <- Path.wildcard("lib/spruce_goose/evidence/*.ex") do
      refute File.read!(f) =~ "isolation:", "#{f} must not pass Ecto's inert isolation option"
    end
  end

  test "no Mix.env, Sandbox detection, or test-only isolation branch in production code" do
    for f <- Path.wildcard("lib/spruce_goose/evidence/*.ex") do
      src = File.read!(f)
      refute src =~ "Mix.env", "#{f} must not branch on Mix.env"
      refute src =~ "Sandbox", "#{f} must not detect the sandbox pool"
    end
  end
end
