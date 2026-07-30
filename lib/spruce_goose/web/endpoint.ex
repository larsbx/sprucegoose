defmodule SpruceGoose.Web.Endpoint do
  @moduledoc """
  Minimal Phoenix endpoint hosting the OAuth 2.1 authorization server and the
  Ash AI MCP server.

  SpruceGoose remains a CLI-first application. This endpoint exists only to
  serve the MCP tool surface and its OAuth token flow, and it is bound to
  loopback by configuration. It is not a general web UI.
  """
  # Bandit rather than Cowboy. Phoenix defaults to Cowboy, which is not a
  # dependency here, so the adapter is set in the endpoint config
  # (see config/config.exs).
  use Phoenix.Endpoint, otp_app: :spruce_goose

  @session_options [
    store: :cookie,
    key: "_spruce_goose_key",
    signing_salt: "sg_mcp_session",
    same_site: "Lax"
  ]

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:spruce_goose, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(SpruceGoose.Web.Router)

  def session_options, do: @session_options
end
