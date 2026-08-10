defmodule SpruceGoose.Ledger.ImportReceipt do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "ledger_import_receipts" do
    field(:actor_id, Ecto.UUID)
    field(:actor_name, :string)
    field(:source_name, :string)
    field(:source_sha256, :string)
    field(:source_bytes, :integer)
    field(:source_lines, :integer)
    field(:task_count, :integer)
    field(:dependency_count, :integer)
    field(:inserted_at, :utc_datetime_usec)
  end
end
