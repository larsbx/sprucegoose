defmodule SpruceGoose.Repo.Migrations.AddAuthorityInstanceIdentity do
  use Ecto.Migration

  def up do
    create table(:authority_instance_identity, primary_key: false) do
      add(:singleton, :boolean, primary_key: true, default: true)
      add(:instance_id, :uuid, null: false)
      add(:purpose, :text, null: false, default: "live")
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:authority_instance_identity, :authority_instance_singleton, check: "singleton")
    )

    create(
      constraint(:authority_instance_identity, :authority_instance_purpose,
        check: "purpose IN ('live', 'recovery')"
      )
    )

    execute("""
    INSERT INTO authority_instance_identity(singleton, instance_id, purpose, inserted_at)
    VALUES (TRUE, gen_random_uuid(), 'live', now())
    """)
  end
end
