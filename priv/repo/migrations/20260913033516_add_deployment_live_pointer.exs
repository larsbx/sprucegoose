defmodule SpruceGoose.Repo.Migrations.AddDeploymentLivePointer do
  @moduledoc """
  The live-release pointer: at most one active deployment per project and
  environment, plus who observed a deployment's health.

  `project_id` is denormalised onto deployments so the pointer's uniqueness is
  a database invariant rather than a join-time convention. Generated with
  `mix ash_postgres.generate_migrations`, then hardened by hand.
  """

  use Ecto.Migration

  def up do
    alter table(:deployments) do
      add(:health_source, :text)
      add(:active, :boolean, null: false, default: false)
      add(:superseded_at, :utc_datetime_usec)
      add(:superseded_by, :text)

      add(
        :project_id,
        references(:projects,
          column: :id,
          name: "deployments_project_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
    end

    execute("""
    UPDATE deployments d SET project_id = rl.project_id
    FROM deployment_releases rl WHERE rl.id = d.release_id AND d.project_id IS NULL
    """)

    execute("ALTER TABLE deployments ALTER COLUMN project_id SET NOT NULL")

    execute("""
    CREATE UNIQUE INDEX deployments_one_active_per_environment
    ON deployments (project_id, environment) WHERE active
    """)

    execute("""
    ALTER TABLE deployments
      ADD CONSTRAINT deployment_pointer_shape CHECK (
        (active = false OR (superseded_at IS NULL AND superseded_by IS NULL)) AND
        ((superseded_at IS NULL) = (superseded_by IS NULL)) AND
        (health_source IS NULL OR health_source IN ('operator', 'adapter'))
      )
    """)

    execute("DROP TRIGGER IF EXISTS deployments_identity_immutable ON deployments")

    execute("""
    CREATE TRIGGER deployments_identity_immutable
    BEFORE UPDATE ON deployments
    FOR EACH ROW
    WHEN (OLD.id IS DISTINCT FROM NEW.id
          OR OLD.deployment_id IS DISTINCT FROM NEW.deployment_id
          OR OLD.release_id IS DISTINCT FROM NEW.release_id
          OR OLD.project_id IS DISTINCT FROM NEW.project_id
          OR OLD.environment IS DISTINCT FROM NEW.environment)
    EXECUTE FUNCTION refuse_deployment_identity_mutation()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS deployments_identity_immutable ON deployments")

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

    execute("ALTER TABLE deployments DROP CONSTRAINT deployment_pointer_shape")
    execute("DROP INDEX deployments_one_active_per_environment")
    drop(constraint(:deployments, "deployments_project_id_fkey"))

    alter table(:deployments) do
      remove(:project_id)
      remove(:superseded_by)
      remove(:superseded_at)
      remove(:active)
      remove(:health_source)
    end
  end
end
