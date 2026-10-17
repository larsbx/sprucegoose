defmodule SpruceGoose.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    verify_sop_adoption!()

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

  @impl true
  def stop(_state) do
    if Application.get_env(:spruce_goose, :start_cli_service, false) do
      :ok =
        Application.fetch_env!(:spruce_goose, :cli_socket_path)
        |> SpruceGoose.CLI.SocketPath.remove()
    end

    :ok
  end

  # The `norm` constitutional root is the digest of the Systemwide SOP. The SOP
  # itself is deployment-owned, so nothing previously checked that the bytes a
  # running service gates on are the bytes this release adopted — a divergence
  # would have been invisible until someone diffed two machines by hand.
  #
  # Refuses at boot rather than warning: a service admitting work under an
  # unreviewed SOP is the failure this gate exists to prevent, and it is far
  # cheaper to catch on start than in an audit. Skipped where no SOP is
  # configured for the environment.
  defp verify_sop_adoption! do
    if Application.get_env(:spruce_goose, :verify_sop_adoption, true) do
      case SpruceGoose.SopGate.verify_adoption() do
        :ok -> :ok
        {:error, message} -> raise message
      end
    end
  end

  defp cli_service_children do
    if Application.fetch_env!(:spruce_goose, :start_cli_service) do
      socket_path = Application.fetch_env!(:spruce_goose, :cli_socket_path)
      timeout = Application.fetch_env!(:spruce_goose, :cli_request_timeout)

      [
        {Task.Supervisor, name: SpruceGoose.CLI.TaskSupervisor},
        {SpruceGoose.CLI.SocketPath, socket_path},
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
