defmodule SpruceGoose.Repo.Migrations.AddAuthorizationRevocations do
  @moduledoc """
  Append-only revocations of issued authorizations, and the operation phase
  shape relaxed so a withdrawal may complete an operation that was never
  started. Generated with `mix ash_postgres.generate_migrations`, then
  hardened by hand.
  """

  use Ecto.Migration

  def up do
    create table(:deployment_authorization_revocations, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:authorization_id, :text, null: false)
      add(:revoked_by, :text, null: false)
      add(:reason, :text, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(
        :authorization_record_id,
        references(:deployment_authorizations,
          column: :id,
          name: "deployment_authorization_revocations_authorization_record_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
    end

    create unique_index(:deployment_authorization_revocations, [:authorization_id],
             name: "deployment_revocations_one_per_authorization_idx"
           )

    execute("""
    ALTER TABLE deployment_authorization_revocations
      ADD CONSTRAINT deployment_revocation_authorization_fk
        FOREIGN KEY (authorization_id) REFERENCES deployment_authorizations(authorization_id),
      ADD CONSTRAINT deployment_revocation_shape CHECK (length(revoked_by) > 0 AND length(reason) > 0)
    """)

    execute("""
    CREATE TRIGGER deployment_authorization_revocations_immutable
    BEFORE UPDATE OR DELETE ON deployment_authorization_revocations
    FOR EACH ROW EXECUTE FUNCTION refuse_deployment_evidence_mutation()
    """)

    # A withdrawn operation completes without ever having started.
    execute("ALTER TABLE deployment_operations DROP CONSTRAINT deployment_operation_phase_shape")

    execute("""
    ALTER TABLE deployment_operations
      ADD CONSTRAINT deployment_operation_phase_shape CHECK (
        operation_id ~ '^dpo-[0-9a-f]{64}$' AND
        phase IN ('requested', 'started', 'completed') AND
        (phase <> 'requested' OR (started_at IS NULL AND completed_at IS NULL AND outcome IS NULL)) AND
        (phase <> 'started' OR (started_at IS NOT NULL AND completed_at IS NULL AND outcome IS NULL)) AND
        (phase <> 'completed' OR (completed_at IS NOT NULL AND outcome IS NOT NULL)) AND
        (outcome IS NULL OR outcome IN ('succeeded', 'failed')) AND
        (evidence_digest IS NULL OR evidence_digest ~ '^[0-9a-f]{64}$')
      )
    """)
  end

  def down do
    execute("ALTER TABLE deployment_operations DROP CONSTRAINT deployment_operation_phase_shape")

    execute("""
    ALTER TABLE deployment_operations
      ADD CONSTRAINT deployment_operation_phase_shape CHECK (
        operation_id ~ '^dpo-[0-9a-f]{64}$' AND
        phase IN ('requested', 'started', 'completed') AND
        (phase = 'requested') = (started_at IS NULL) AND
        (phase = 'completed') = (completed_at IS NOT NULL) AND
        (phase = 'completed') = (outcome IS NOT NULL) AND
        (outcome IS NULL OR outcome IN ('succeeded', 'failed')) AND
        (evidence_digest IS NULL OR evidence_digest ~ '^[0-9a-f]{64}$')
      )
    """)

    execute(
      "DROP TRIGGER IF EXISTS deployment_authorization_revocations_immutable ON deployment_authorization_revocations"
    )

    drop(table(:deployment_authorization_revocations))
  end
end
