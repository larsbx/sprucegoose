ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(SpruceGoose.Repo, :manual)

defmodule SpruceGoose.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias SpruceGoose.Repo
      import Ecto.Query
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(SpruceGoose.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end
end
