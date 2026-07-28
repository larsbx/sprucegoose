defmodule SpruceGoose.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SpruceGoose.Repo,
        {Oban, Application.fetch_env!(:spruce_goose, Oban)}
      ] ++
        if(Application.fetch_env!(:spruce_goose, :start_outbox_dispatcher),
          do: [SpruceGoose.Outbox.Dispatcher],
          else: []
        )

    Supervisor.start_link(children, strategy: :one_for_one, name: SpruceGoose.Supervisor)
  end
end
