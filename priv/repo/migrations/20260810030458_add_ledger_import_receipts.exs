defmodule SpruceGoose.Repo.Migrations.AddLedgerImportReceipts do
  use Ecto.Migration

  def up do
    create table(:ledger_import_receipts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:actor_id, references(:actors, type: :uuid, on_delete: :restrict), null: false)
      add(:actor_name, :text, null: false)
      add(:source_name, :text, null: false)
      add(:source_sha256, :text, null: false)
      add(:source_bytes, :bigint, null: false)
      add(:source_lines, :bigint, null: false)
      add(:task_count, :bigint, null: false)
      add(:dependency_count, :bigint, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:ledger_import_receipts, [:actor_id, :inserted_at]))

    create(
      constraint(:ledger_import_receipts, :ledger_import_receipts_sha256_check,
        check: "source_sha256 ~ '^[0-9a-f]{64}$'"
      )
    )

    execute("""
    CREATE FUNCTION spruce_goose_protect_ledger_import_receipt() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'ledger import receipts are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER ledger_import_receipts_immutable
    BEFORE UPDATE OR DELETE ON ledger_import_receipts
    FOR EACH ROW EXECUTE FUNCTION spruce_goose_protect_ledger_import_receipt();
    """)
  end
end
