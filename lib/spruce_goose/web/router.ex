defmodule SpruceGoose.Web.Router do
  @moduledoc """
  Routes for the OAuth 2.1 authorization server and the Ash AI MCP server.

  The MCP surface is protected by `BearerPlug`, which validates an
  `Authorization: Bearer <jwt>` header against `SpruceGoose.Oauth2Server`.
  Missing or invalid tokens fail closed with `401` per RFC 6750.
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

  # Bearer-token gate for the MCP surface. `required?: true` means an absent
  # or invalid token is rejected before any tool is reachable.
  pipeline :mcp_protected do
    plug(:accepts, ["json"])

    plug(AshAuthentication.Phoenix.Oauth2Server.BearerPlug,
      oauth2_server: SpruceGoose.Oauth2Server,
      required?: true,
      scope: "mcp"
    )
  end

  # User-facing consent step (browser pipeline, CSRF protected).
  scope "/" do
    pipe_through(:browser)
    oauth2_server_consent_routes(oauth2_server: SpruceGoose.Oauth2Server)
  end

  # Client-facing protocol endpoints: /oauth/token, /oauth/register,
  # /oauth/revoke and the .well-known discovery documents.
  scope "/" do
    pipe_through(:api)
    oauth2_server_protocol_routes(oauth2_server: SpruceGoose.Oauth2Server)
  end

  # The MCP server itself. Read-only tools defined on SpruceGoose.Workflows.
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
