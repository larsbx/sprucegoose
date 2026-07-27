defmodule SpruceGoose.Repo.Migrations.RenamePostgresIdentifiers do
  use Ecto.Migration

  def up do
    rename(table(:orchestrator_authority), to: table(:spruce_goose_authority))

    execute("""
    ALTER TRIGGER orchestrator_authority_irreversible
    ON spruce_goose_authority
    RENAME TO spruce_goose_authority_irreversible
    """)
  end

  def down do
    execute("""
    ALTER TRIGGER spruce_goose_authority_irreversible
    ON spruce_goose_authority
    RENAME TO orchestrator_authority_irreversible
    """)

    rename(table(:spruce_goose_authority), to: table(:orchestrator_authority))
  end
end
