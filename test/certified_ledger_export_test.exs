defmodule SpruceGoose.CertifiedLedgerExportTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.Authz
  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Kernel.{CertifiedEvent, ContentID, LedgerExport}
  alias SpruceGoose.Kernel.Postgres.EventLedger

  @roots Map.new(
           ~w(ontology schema norm policy grant_epoch agent_charter interpreter evidence_policy),
           &{&1, "sha256:" <> String.duplicate("e", 64)}
         )

  setup do
    Repo.query!("TRUNCATE certified_event_rekeys, certified_events RESTART IDENTITY")
    dir = Path.join(System.tmp_dir!(), "sprucegoose-export-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    system = Ash.read_one!(Ash.Query.filter_input(Actor, name: "test-system"), authorize?: false)
    {:ok, dir: dir, system: system}
  end

  test "new events are written in jcs-v1; legacy rows stay etf-v1 and are rekeyed once", %{
    dir: dir,
    system: system
  } do
    {:ok, legacy} = CertifiedEvent.new(attrs("legacy", %{"n" => 1}), :etf)
    {:ok, _, _} = EventLedger.append(EventLedger.new(), legacy)
    {:ok, current} = CertifiedEvent.new(attrs("current", %{"n" => 2}))
    {:ok, _, _} = EventLedger.append(EventLedger.new(), current)

    assert %{rows: [["etf-v1"], ["jcs-v1"]]} =
             Repo.query!("SELECT canonical_form FROM certified_events ORDER BY sequence")

    # Reads re-derive each row in its own form.
    assert {:ok, [^legacy, ^current]} = EventLedger.read(EventLedger.new(), "export:test")
    assert {:ok, ["export:test"]} = EventLedger.streams(EventLedger.new())

    # The JCS identity of the legacy event is unknown to verify/2 until the re-rooting record exists.
    {:ok, as_jcs} = CertifiedEvent.new(attrs("legacy", %{"n" => 1}))
    assert {:error, :not_found} = EventLedger.verify(EventLedger.new(), as_jcs.identity)

    assert {:ok, %{rekeyed: 1, record_digest: record}} =
             Authz.with_actor(system, fn -> LedgerExport.rekey() end)

    assert byte_size(record) == 64
    assert :ok = EventLedger.verify(EventLedger.new(), as_jcs.identity)
    assert :ok = EventLedger.verify(EventLedger.new(), legacy.identity)
    assert {:error, :already_rekeyed} = Authz.with_actor(system, fn -> LedgerExport.rekey() end)

    assert {:ok, [adoption]} = EventLedger.read(EventLedger.new(), "authority:kernel")
    assert adoption.event_type == "CanonicalFormAdopted"
    assert adoption.payload["rekeyed_events"] == 1
    assert adoption.canonical_form == :jcs

    assert {:error, %Postgrex.Error{postgres: %{message: "certified events are immutable"}}} =
             Ecto.Adapters.SQL.query(Repo, "DELETE FROM certified_event_rekeys", [],
               mode: :savepoint
             )

    # Export, then verify the file with the non-BEAM verifier.
    path = Path.join(dir, "ledger.jsonl")
    assert {:ok, %{events: 3}} = Executor.run({:export_certified_ledger, path}, system.name)
    assert {:error, message} = Authz.with_actor(system, fn -> LedgerExport.export(path) end)
    assert message =~ "refusing to overwrite"

    [header | lines] = path |> File.read!() |> String.split("\n", trim: true)

    assert %{"schema" => "sprucegoose-certified-ledger-export-v1", "events" => 3} =
             Jason.decode!(header)

    [first, second, third] = Enum.map(lines, &Jason.decode!/1)
    assert first["canonical_form"] == "etf-v1"
    assert first["jcs_identity"] == "sha256:" <> as_jcs.identity.digest
    assert second["canonical_form"] == "jcs-v1" and second["jcs_identity"] == second["identity"]
    assert third["event_type"] == "CanonicalFormAdopted"

    if System.find_executable("python3") do
      {output, status} =
        System.cmd("python3", ["-I", "scripts/verify-certified-ledger.py", path],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "verified=2 legacy=1 failed=0"

      # A tampered export fails the independent verifier.
      tampered = String.replace(File.read!(path), ~s("n":2), ~s("n":3))
      File.write!(Path.join(dir, "tampered.jsonl"), tampered)

      {output, status} =
        System.cmd(
          "python3",
          ["-I", "scripts/verify-certified-ledger.py", Path.join(dir, "tampered.jsonl")],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "identity mismatch"
    end
  end

  test "export and rekey require admin at global scope" do
    reader =
      Ash.create!(Actor, %{name: "export-reader", kind: :agent, created_by: "t"},
        authorize?: false
      )

    Ash.create!(Grant, %{actor_id: reader.id, role: :reader, scope: "*", granted_by: "t"},
      authorize?: false
    )

    assert {:error, message} = Executor.run({:export_certified_ledger, "/tmp/x"}, reader.name)
    assert message =~ "admin"
    assert {:error, message} = Executor.run(:rekey_certified_ledger, reader.name)
    assert message =~ "admin"
  end

  test "the identity of a legacy event is honoured in both forms by ContentID" do
    {:ok, etf} = CertifiedEvent.new(attrs("x", %{}), :etf)
    assert :ok = ContentID.verify(etf.identity, etf.canonical_bytes)
  end

  defp attrs(key, payload),
    do: %{
      stream: "export:test",
      event_type: "Observed",
      idempotency_key: key,
      payload: payload,
      roots: @roots
    }
end
