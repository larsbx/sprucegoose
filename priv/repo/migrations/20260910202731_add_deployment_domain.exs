defmodule SpruceGoose.Repo.Migrations.AddDeploymentDomain do
  @moduledoc """
  The deployment domain: accepted releases, authoritative deployment records,
  single-use execution authorizations, and stably identified operations.

  Generated with `mix ash_postgres.generate_migrations`, then reordered and
  hardened by hand. Releases and authorizations are immutable evidence and
  refuse UPDATE and DELETE. Deployments and operations are projections whose
  identity columns are frozen and whose rows are never deleted.
  """

  use Ecto.Migration

  @hex40 "'^[0-9a-f]{40}$'"
  @hex64 "'^[0-9a-f]{64}$'"

  def up do
    create table(:deployment_releases, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:release_id, :text, null: false)
      add(:forge_instance, :text, null: false)
      add(:repository, :text, null: false)
      add(:source_commit, :text, null: false)
      add(:pipeline_number, :bigint, null: false)
      add(:pipeline_digest, :text, null: false)
      add(:artifacts, :map, null: false)
      add(:accepted_by, :text, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(
        :project_id,
        references(:projects,
          column: :id,
          name: "deployment_releases_project_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
    end

    create unique_index(:deployment_releases, [:release_id],
             name: "deployment_releases_stable_release_id_index"
           )

    execute("""
    ALTER TABLE deployment_releases
      ADD CONSTRAINT deployment_release_identity_shape CHECK (
        release_id ~ '^rel-[0-9a-f]{64}$' AND
        length(forge_instance) > 0 AND
        repository ~ '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$' AND
        source_commit ~ #{@hex40} AND
        pipeline_number > 0 AND
        pipeline_digest ~ #{@hex64} AND
        jsonb_typeof(artifacts) = 'object' AND artifacts <> '{}'::jsonb
      )
    """)

    create table(:deployments, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:deployment_id, :text, null: false)
      add(:environment, :text, null: false)
      add(:requires_routing, :boolean, null: false, default: false)
      add(:state, :text, null: false, default: "queued")
      add(:health_status, :text, null: false, default: "unknown")
      add(:health_detail, :text)
      add(:cancellation_reason, :text)
      add(:rollback_target_id, :text)
      add(:pinned, :boolean, null: false, default: false)
      add(:terminal_at, :utc_datetime_usec)
      add(:reclaimed_at, :utc_datetime_usec)
      add(:last_event, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(
        :release_id,
        references(:deployment_releases,
          column: :id,
          name: "deployments_release_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
    end

    create unique_index(:deployments, [:deployment_id],
             name: "deployments_stable_deployment_id_index"
           )

    execute("""
    ALTER TABLE deployments
      ADD CONSTRAINT deployment_shape CHECK (
        environment IN ('preview', 'staging', 'production') AND
        state IN ('queued', 'building', 'staged', 'deploying', 'verifying', 'ready',
                  'failed', 'rolling_back', 'rolled_back', 'cancelled') AND
        health_status IN ('unknown', 'healthy', 'unhealthy') AND
        (last_event IS NULL OR last_event ~ #{@hex64}) AND
        (reclaimed_at IS NULL OR environment = 'preview')
      )
    """)

    create table(:deployment_authorizations, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:authorization_id, :text, null: false)
      add(:action, :text, null: false)
      add(:target_deployment_id, :text)
      add(:approved_by, :text, null: false)
      add(:approval_reference, :text, null: false)
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)

      add(
        :deployment_id,
        references(:deployments,
          column: :id,
          name: "deployment_authorizations_deployment_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
    end

    create unique_index(:deployment_authorizations, [:authorization_id],
             name: "deployment_authorizations_stable_authorization_id_index"
           )

    execute("""
    ALTER TABLE deployment_authorizations
      ADD CONSTRAINT deployment_authorization_shape CHECK (
        action IN ('execute_deploy', 'execute_rollback', 'execute_reclaim') AND
        ((action = 'execute_rollback' AND length(target_deployment_id) > 0) OR
         (action <> 'execute_rollback' AND target_deployment_id IS NULL)) AND
        length(approved_by) > 0 AND length(approval_reference) > 0 AND
        expires_at > issued_at AND expires_at <= issued_at + interval '1 hour'
      )
    """)

    create table(:deployment_operations, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:operation_id, :text, null: false)
      add(:authorization_id, :text, null: false)
      add(:action, :text, null: false)
      add(:target_deployment_id, :text)
      add(:phase, :text, null: false, default: "requested")
      add(:outcome, :text)
      add(:executor_id, :text)
      add(:evidence_digest, :text)
      add(:detail, :text)
      add(:observation_count, :bigint, null: false, default: 0)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(
        :deployment_id,
        references(:deployments,
          column: :id,
          name: "deployment_operations_deployment_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
    end

    # One operation per authorization is the single-use invariant.
    create unique_index(:deployment_operations, [:authorization_id],
             name: "deployment_operations_one_operation_per_authorization_index"
           )

    create unique_index(:deployment_operations, [:operation_id],
             name: "deployment_operations_stable_operation_id_index"
           )

    execute("""
    ALTER TABLE deployment_operations
      ADD CONSTRAINT deployment_operation_authorization_fk
        FOREIGN KEY (authorization_id) REFERENCES deployment_authorizations(authorization_id),
      ADD CONSTRAINT deployment_operation_phase_shape CHECK (
        operation_id ~ '^dpo-[0-9a-f]{64}$' AND
        phase IN ('requested', 'started', 'completed') AND
        (phase = 'requested') = (started_at IS NULL) AND
        (phase = 'completed') = (completed_at IS NOT NULL) AND
        (phase = 'completed') = (outcome IS NOT NULL) AND
        (outcome IS NULL OR outcome IN ('succeeded', 'failed')) AND
        (evidence_digest IS NULL OR evidence_digest ~ #{@hex64})
      )
    """)

    execute("""
    CREATE FUNCTION refuse_deployment_evidence_mutation() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION '% is immutable', TG_TABLE_NAME;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER deployment_releases_immutable
    BEFORE UPDATE OR DELETE ON deployment_releases
    FOR EACH ROW EXECUTE FUNCTION refuse_deployment_evidence_mutation()
    """)

    execute("""
    CREATE TRIGGER deployment_authorizations_immutable
    BEFORE UPDATE OR DELETE ON deployment_authorizations
    FOR EACH ROW EXECUTE FUNCTION refuse_deployment_evidence_mutation()
    """)

    # Projections may advance but never lose their identity or disappear.
    execute("""
    CREATE FUNCTION refuse_deployment_projection_delete() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION '% rows are never deleted', TG_TABLE_NAME;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE FUNCTION refuse_deployment_identity_mutation() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION '% identity is immutable', TG_TABLE_NAME;
    END;
    $$ LANGUAGE plpgsql
    """)

    for table <- ["deployments", "deployment_operations"] do
      execute("""
      CREATE TRIGGER #{table}_never_deleted
      BEFORE DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION refuse_deployment_projection_delete()
      """)
    end

    execute("""
    CREATE TRIGGER deployments_identity_immutable
    BEFORE UPDATE ON deployments
    FOR EACH ROW
    WHEN (OLD.id IS DISTINCT FROM NEW.id
          OR OLD.deployment_id IS DISTINCT FROM NEW.deployment_id
          OR OLD.release_id IS DISTINCT FROM NEW.release_id
          OR OLD.environment IS DISTINCT FROM NEW.environment)
    EXECUTE FUNCTION refuse_deployment_identity_mutation()
    """)

    execute("""
    CREATE TRIGGER deployment_operations_identity_immutable
    BEFORE UPDATE ON deployment_operations
    FOR EACH ROW
    WHEN (OLD.id IS DISTINCT FROM NEW.id
          OR OLD.operation_id IS DISTINCT FROM NEW.operation_id
          OR OLD.authorization_id IS DISTINCT FROM NEW.authorization_id
          OR OLD.action IS DISTINCT FROM NEW.action
          OR OLD.deployment_id IS DISTINCT FROM NEW.deployment_id)
    EXECUTE FUNCTION refuse_deployment_identity_mutation()
    """)
  end

  def down do
    for {trigger, table} <- [
          {"deployment_operations_identity_immutable", "deployment_operations"},
          {"deployment_operations_never_deleted", "deployment_operations"},
          {"deployments_identity_immutable", "deployments"},
          {"deployments_never_deleted", "deployments"},
          {"deployment_authorizations_immutable", "deployment_authorizations"},
          {"deployment_releases_immutable", "deployment_releases"}
        ] do
      execute("DROP TRIGGER IF EXISTS #{trigger} ON #{table}")
    end

    execute("DROP FUNCTION IF EXISTS refuse_deployment_identity_mutation()")
    execute("DROP FUNCTION IF EXISTS refuse_deployment_projection_delete()")
    execute("DROP FUNCTION IF EXISTS refuse_deployment_evidence_mutation()")
    drop(table(:deployment_operations))
    drop(table(:deployment_authorizations))
    drop(table(:deployments))
    drop(table(:deployment_releases))
  end
end
