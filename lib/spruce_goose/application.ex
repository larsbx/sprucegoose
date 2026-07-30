defmodule SpruceGoose.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {AshAuthentication.Oauth2Server.Supervisor, [otp_app: :spruce_goose]},
        SpruceGoose.Repo,
        {Oban, Application.fetch_env!(:spruce_goose, Oban)},
        {AshAuthentication.Supervisor, [otp_app: :spruce_goose]}
      ] ++
        if(Application.fetch_env!(:spruce_goose, :start_outbox_dispatcher),
          do: [SpruceGoose.Outbox.Dispatcher],
          else: []
        ) ++
        if(Application.get_env(:spruce_goose, :start_web_endpoint, false),
          do: [SpruceGoose.Web.Endpoint],
          else: []
        )

    Supervisor.start_link(children, strategy: :one_for_one, name: SpruceGoose.Supervisor)
  end
end
