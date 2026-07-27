defmodule SpruceGoose.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [SpruceGoose.Repo]
    Supervisor.start_link(children, strategy: :one_for_one, name: SpruceGoose.Supervisor)
  end
end
