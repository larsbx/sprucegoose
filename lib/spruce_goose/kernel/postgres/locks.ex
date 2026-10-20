defmodule SpruceGoose.Kernel.Postgres.Locks do
  @moduledoc "Transaction-scoped advisory locks; the key is hashed, so any string names a lock."

  @behaviour SpruceGoose.Kernel.Locks

  alias SpruceGoose.Repo

  @impl true
  def acquire(key) do
    # AUTHORIZATION: a lock reads nothing; callers authorize before taking it.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    :ok
  end
end
