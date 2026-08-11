defmodule SpruceGoose.Authority do
  @moduledoc false

  alias SpruceGoose.Repo

  def mode do
    # AUTHORIZATION: read-only system authority gate, not operator data access.
    case Ecto.Adapters.SQL.query!(Repo, "SELECT mode FROM spruce_goose_authority WHERE id = TRUE").rows do
      [[mode]] -> {:ok, mode}
      _ -> {:error, "authority state is missing"}
    end
  end

  def require_tuxedo do
    case mode() do
      {:ok, "tuxedo"} -> :ok
      {:ok, mode} -> {:error, "ledger import is disabled while #{mode} is authoritative"}
      error -> error
    end
  end
end
