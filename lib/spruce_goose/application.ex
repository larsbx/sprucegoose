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
        cli_service_children() ++
        if(Application.get_env(:spruce_goose, :start_web_endpoint, false),
          do: [SpruceGoose.Web.Endpoint],
          else: []
        )

    Supervisor.start_link(children, strategy: :one_for_one, name: SpruceGoose.Supervisor)
  end

  defp cli_service_children do
    if Application.fetch_env!(:spruce_goose, :start_cli_service) do
      socket_path = Application.fetch_env!(:spruce_goose, :cli_socket_path)
      timeout = Application.fetch_env!(:spruce_goose, :cli_request_timeout)

      [
        {Task.Supervisor, name: SpruceGoose.CLI.TaskSupervisor},
        Supervisor.child_spec(
          {Bandit,
           plug:
             {SpruceGoose.CLI.SocketPlug,
              supervisor: SpruceGoose.CLI.TaskSupervisor, timeout: timeout},
           scheme: :http,
           ip: {:local, socket_path},
           port: 0,
           startup_log: false},
          id: SpruceGoose.CLI.Server
        )
      ]
    else
      []
    end
  end
end
