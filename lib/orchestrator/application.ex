defmodule Orchestrator.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Orchestrator.Repo]
    Supervisor.start_link(children, strategy: :one_for_one, name: Orchestrator.Supervisor)
  end
end
