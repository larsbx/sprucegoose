defmodule SpruceGoose.PostgresEventLedgerTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Kernel.CertifiedEvent
  alias SpruceGoose.Kernel.Postgres.EventLedger

  setup do
    Repo.query!("TRUNCATE certified_events RESTART IDENTITY")
    %{ledger: EventLedger.new()}
  end

  test "appends, reads, verifies, and recovers ordered certified events", %{ledger: ledger} do
    first = event("observed-1", "one")
    second = event("observed-2", "two")

    assert {:ok, first_id, ^ledger} = EventLedger.append(ledger, first)
    assert {:ok, _second_id, ^ledger} = EventLedger.append(ledger, second)
    assert {:ok, [^first, ^second]} = EventLedger.read(EventLedger.new(), first.stream)
    assert :ok = EventLedger.verify(EventLedger.new(), first_id)
  end

  test "idempotency permits identical content and refuses conflicting reuse", %{ledger: ledger} do
    accepted = event("same-key", "accepted")
    conflicting = event("same-key", "substituted")

    assert {:ok, identity, ^ledger} = EventLedger.append(ledger, accepted)
    assert {:ok, ^identity, ^ledger} = EventLedger.append(ledger, accepted)
    assert {:error, :idempotency_conflict} = EventLedger.append(ledger, conflicting)
  end

  test "refuses missing constitutive roots before database access", %{ledger: ledger} do
    {:ok, event} =
      CertifiedEvent.new(%{
        stream: "project:canary",
        event_type: "CanaryObserved",
        idempotency_key: "missing-root",
        payload: %{"value" => "observed"},
        roots: Map.delete(roots(), "interpreter")
      })

    assert {:error, {:missing_root, "interpreter"}} = EventLedger.append(ledger, event)
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM certified_events")
  end

  test "database refuses update and delete of certified history", %{ledger: ledger} do
    assert {:ok, _, ^ledger} = EventLedger.append(ledger, event("immutable", "value"))

    assert {:error, %Postgrex.Error{postgres: %{code: :raise_exception}}} =
             Repo.query("UPDATE certified_events SET event_type = 'altered'")

    assert {:error, %Postgrex.Error{postgres: %{code: :raise_exception}}} =
             Repo.query("DELETE FROM certified_events")
  end

  @tag :separate_sessions
  test "concurrent appends allocate one contiguous position per stream" do
    parent = self()

    tasks =
      for index <- 1..12 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          EventLedger.append(EventLedger.new(), event("concurrent-#{index}", "#{index}"))
        end)
      end

    assert Enum.all?(Task.await_many(tasks, 15_000), &match?({:ok, _, _}, &1))

    assert %{rows: rows} =
             Repo.query!(
               "SELECT stream_position FROM certified_events " <>
                 "WHERE stream = 'project:canary' ORDER BY stream_position"
             )

    assert Enum.map(rows, &hd/1) == Enum.to_list(1..12)
  end

  @tag :separate_sessions
  test "concurrent identical retries converge on one row and identity" do
    parent = self()
    event = event("concurrent-identical", "same")

    tasks =
      for _index <- 1..12 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          EventLedger.append(EventLedger.new(), event)
        end)
      end

    results = Task.await_many(tasks, 15_000)
    assert Enum.all?(results, &match?({:ok, identity, _} when identity == event.identity, &1))

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM certified_events " <>
                 "WHERE stream = 'project:canary' AND idempotency_key = 'concurrent-identical'"
             )
  end

  defp event(key, value) do
    {:ok, event} =
      CertifiedEvent.new(%{
        stream: "project:canary",
        event_type: "CanaryObserved",
        idempotency_key: key,
        payload: %{"value" => value},
        roots: roots()
      })

    event
  end

  defp roots do
    Map.new(
      ~w(ontology schema norm policy grant_epoch agent_charter interpreter evidence_policy),
      &{&1, "sha256:" <> (:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower))}
    )
  end
end
