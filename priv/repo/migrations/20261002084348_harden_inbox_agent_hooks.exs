defmodule SpruceGoose.Repo.Migrations.HardenInboxAgentHooks do
  use Ecto.Migration

  def up do
    create table(:agent_hook_deliveries, primary_key: false) do
      add(:run_id, references(:agent_hook_runs, type: :uuid), primary_key: true)
      add(:claim_id, :uuid)
      add(:claimed_until, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:attempts, :integer, null: false, default: 0)
      timestamps(type: :utc_datetime_usec, default: fragment("now()"))
    end

    create unique_index(:agent_hook_runs, [:event_id, :hook_id, :hook_version])

    create constraint(:agent_hook_deliveries, :valid_agent_hook_delivery,
             check:
               "attempts >= 0 AND ((claim_id IS NULL) = (claimed_until IS NULL)) AND (completed_at IS NULL OR claim_id IS NULL)"
           )

    create constraint(:inbox_triage_results, :typed_inbox_triage_result,
             check:
               "(outcome = 'proposed' AND proposal IS NOT NULL AND jsonb_typeof(proposal) = 'object' AND proposal_digest ~ '^[0-9a-f]{64}$' AND reason IS NULL) OR (outcome IN ('refused', 'failed') AND proposal IS NULL AND proposal_digest IS NULL AND length(reason) BETWEEN 1 AND 4000)"
           )

    execute(
      "ALTER TABLE agent_hook_runs ADD CONSTRAINT agent_hook_runs_event_id_fkey FOREIGN KEY (event_id) REFERENCES outbox_events(id)"
    )

    execute(
      "ALTER TABLE agent_hook_runs ADD CONSTRAINT agent_hook_runs_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES actors(id)"
    )

    execute("""
    CREATE FUNCTION spruce_goose_agent_hook_immutable() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION '% are immutable', TG_TABLE_NAME;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER agent_hook_runs_immutable BEFORE UPDATE OR DELETE ON agent_hook_runs FOR EACH ROW EXECUTE FUNCTION spruce_goose_agent_hook_immutable()"
    )

    execute(
      "CREATE TRIGGER inbox_triage_results_immutable BEFORE UPDATE OR DELETE ON inbox_triage_results FOR EACH ROW EXECUTE FUNCTION spruce_goose_agent_hook_immutable()"
    )

    execute("""
    CREATE FUNCTION spruce_goose_bind_triage_result() RETURNS trigger AS $$
    DECLARE
      bound_actor uuid;
      bound_context text;
    BEGIN
      SELECT actor_id, context_digest INTO bound_actor, bound_context
      FROM agent_hook_runs WHERE id = NEW.run_id;
      IF NEW.actor_id IS DISTINCT FROM bound_actor OR NEW.context_digest IS DISTINCT FROM bound_context THEN
        RAISE EXCEPTION 'triage result must bind its immutable run';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER inbox_triage_results_bind_run BEFORE INSERT ON inbox_triage_results FOR EACH ROW EXECUTE FUNCTION spruce_goose_bind_triage_result()"
    )

    execute("""
    CREATE FUNCTION spruce_goose_guard_hook_delivery() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' OR NEW.run_id IS DISTINCT FROM OLD.run_id THEN
        RAISE EXCEPTION 'hook delivery identity cannot be removed or replaced';
      END IF;
      IF OLD.completed_at IS NOT NULL AND NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'completed hook delivery is immutable';
      END IF;
      IF NEW.completed_at IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM inbox_triage_results WHERE run_id = NEW.run_id
      ) THEN
        RAISE EXCEPTION 'hook completion requires a terminal result';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER agent_hook_deliveries_guard BEFORE UPDATE OR DELETE ON agent_hook_deliveries FOR EACH ROW EXECUTE FUNCTION spruce_goose_guard_hook_delivery()"
    )
  end

  def down do
    execute("DROP TRIGGER agent_hook_deliveries_guard ON agent_hook_deliveries")
    execute("DROP FUNCTION spruce_goose_guard_hook_delivery()")
    execute("DROP TRIGGER inbox_triage_results_bind_run ON inbox_triage_results")
    execute("DROP FUNCTION spruce_goose_bind_triage_result()")
    execute("DROP TRIGGER inbox_triage_results_immutable ON inbox_triage_results")
    execute("DROP TRIGGER agent_hook_runs_immutable ON agent_hook_runs")
    execute("DROP FUNCTION spruce_goose_agent_hook_immutable()")
    execute("ALTER TABLE agent_hook_runs DROP CONSTRAINT agent_hook_runs_event_id_fkey")
    execute("ALTER TABLE agent_hook_runs DROP CONSTRAINT agent_hook_runs_actor_id_fkey")
    drop(constraint(:inbox_triage_results, :typed_inbox_triage_result))
    drop(unique_index(:agent_hook_runs, [:event_id, :hook_id, :hook_version]))
    drop(table(:agent_hook_deliveries))
  end
end
