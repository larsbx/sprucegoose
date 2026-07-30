import Config

config :spruce_goose,
       :systemwide_sop_path,
       System.get_env(
         "SYSTEMWIDE_SOP_PATH",
         "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md"
       )

outbox_enabled? = System.get_env("OUTBOX_DISPATCHER_ENABLED", "false") in ["1", "true"]

outbox_handler =
  case System.get_env("OUTBOX_HANDLER") do
    nil ->
      nil

    name ->
      name
      |> String.trim_leading("Elixir.")
      |> String.split(".")
      |> Module.concat()
  end

if outbox_enabled? and is_nil(outbox_handler),
  do: raise("OUTBOX_HANDLER is required when OUTBOX_DISPATCHER_ENABLED is true")

config :spruce_goose,
  start_outbox_dispatcher: outbox_enabled?,
  outbox_handler: outbox_handler

# MCP/OAuth endpoint. Opt-in and loopback-only.
#
# SpruceGoose is CLI-first; nothing binds a port unless this is switched on.
# The bind address is deliberately not configurable from the environment:
# exposing the MCP tool surface beyond loopback is a separate, governed
# security decision, not an ops toggle.
mcp_enabled? = System.get_env("SPRUCE_GOOSE_MCP_ENABLED", "false") in ["1", "true"]

config :spruce_goose, :start_web_endpoint, mcp_enabled?

if mcp_enabled? do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is required when SPRUCE_GOOSE_MCP_ENABLED is true"

  if byte_size(secret_key_base) < 64 do
    raise "SECRET_KEY_BASE must be at least 64 bytes; generate one with `mix phx.gen.secret`"
  end

  for {var, setting} <- [
        {"TOKEN_SIGNING_SECRET", :token_signing_secret},
        {"OAUTH2_SIGNING_SECRET", :oauth2_signing_secret}
      ] do
    case System.get_env(var) do
      nil ->
        if config_env() == :prod,
          do: raise("#{var} is required when SPRUCE_GOOSE_MCP_ENABLED is true")

      value ->
        config :spruce_goose, [{setting, value}]
    end
  end

  config :spruce_goose, SpruceGoose.Web.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("MCP_PORT", "4000"))],
    secret_key_base: secret_key_base,
    server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is required in production"

  ssl = System.get_env("DATABASE_SSL", "true") not in ["false", "0"]

  config :spruce_goose, SpruceGoose.Repo,
    url: database_url,
    ssl: ssl,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  config :spruce_goose,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")
end
