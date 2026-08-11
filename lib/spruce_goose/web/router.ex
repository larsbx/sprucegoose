defmodule SpruceGoose.Web.Router do
  @moduledoc """
  Routes for the OAuth 2.1 authorization server and the Ash AI MCP server.

  The MCP surface is protected by `BearerPlug`, which validates an
  `Authorization: Bearer *** header against `SpruceGoose.Oauth2Server`, and by
  `RequireScopePlug`, which enforces the exact `mcp` delegated scope. Missing,
  invalid, or insufficient tokens fail closed before actor resolution.
  """
  use Phoenix.Router
  use AshAuthentication.Phoenix.Oauth2Server.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :mcp_protected do
    plug(:accepts, ["json"])

    plug(AshAuthentication.Phoenix.Oauth2Server.BearerPlug,
      oauth2_server: SpruceGoose.Oauth2Server,
      required?: true,
      scope: "mcp"
    )

    plug(AshAuthentication.Phoenix.Oauth2Server.RequireScopePlug,
      oauth2_server: SpruceGoose.Oauth2Server,
      scope: "mcp"
    )

    # Resolve only the verified token claim client_id through the governed
    # immutable client-ID -> actor-ID map. OAuth user `sub` and registration
    # metadata are not actor authority inputs.
    plug(SpruceGoose.Web.ActorPlug)
  end

  scope "/" do
    pipe_through(:browser)
    oauth2_server_consent_routes(oauth2_server: SpruceGoose.Oauth2Server)
  end

  scope "/" do
    pipe_through(:api)
    oauth2_server_protocol_routes(oauth2_server: SpruceGoose.Oauth2Server)
  end

  scope "/mcp" do
    pipe_through(:mcp_protected)

    forward("/", AshAi.Mcp.Router,
      tools: [
        :list_tasks,
        :list_projects,
        :list_roadmaps,
        :list_workflows,
        :list_todos
      ],
      protocol_version_statement: "2024-11-05",
      otp_app: :spruce_goose
    )
  end
end
