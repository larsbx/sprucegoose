defmodule Orchestrator.Authority do
  @moduledoc false

  alias Orchestrator.Repo

  def mode do
    case Ecto.Adapters.SQL.query!(Repo, "SELECT mode FROM orchestrator_authority WHERE id = TRUE").rows do
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
