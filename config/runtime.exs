import Config

if config_env() == :test do
  if marker = System.get_env("SPRUCE_GOOSE_TEST_AUTHORITY_MARKER") do
    config :spruce_goose, :authority_host_marker, marker
  end

  if System.get_env("SPRUCE_GOOSE_TEST_DOGFOOD") == "true" do
    config :spruce_goose, SpruceGoose.Repo, pool: DBConnection.ConnectionPool
  end
end

config :spruce_goose,
       :systemwide_sop_path,
       System.get_env(
         "SYSTEMWIDE_SOP_PATH",
         if(config_env() == :test,
           do: Path.expand("../test/fixtures/systemwide-sop.md", __DIR__),
           else: "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md"
         )
       )

outbox_flag = System.get_env("OUTBOX_DISPATCHER_ENABLED", "false")
outbox_enabled? = outbox_flag == "1" or outbox_flag == "true"
oban_enabled? = System.get_env("SPRUCE_GOOSE_OBAN_ENABLED", "true") in ["1", "true"]

if outbox_enabled? and not oban_enabled? do
  raise "OUTBOX_DISPATCHER_ENABLED requires SPRUCE_GOOSE_OBAN_ENABLED"
end

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

if outbox_enabled? do
  case SpruceGoose.Outbox.Dispatcher.validate_handler(outbox_handler) do
    :ok -> :ok
    {:error, message} -> raise message
  end
end

config :spruce_goose,
  start_outbox_dispatcher: outbox_enabled?,
  outbox_handler: outbox_handler

if not oban_enabled? do
  config :spruce_goose, Oban, queues: false, plugins: false
end

config :spruce_goose,
  ledger_import_root: System.get_env("LEDGER_IMPORT_ROOT"),
  ledger_max_bytes: String.to_integer(System.get_env("LEDGER_MAX_BYTES", "1048576")),
  ledger_max_lines: String.to_integer(System.get_env("LEDGER_MAX_LINES", "10000")),
  ledger_open_timeout_ms: String.to_integer(System.get_env("LEDGER_OPEN_TIMEOUT_MS", "1000")),
  ledger_recovery_mode: System.get_env("LEDGER_RECOVERY_MODE", "false") in ["1", "true"],
  ledger_recovery_database: System.get_env("LEDGER_RECOVERY_DATABASE")

config :spruce_goose,
  forgejo_read_token_file:
    System.get_env(
      "SPRUCE_GOOSE_FORGEJO_READ_TOKEN_FILE",
      "/home/admin-papa/.config/sprucegoose/forgejo-read-token"
    )

config :spruce_goose,
  artifact_store_root:
    System.get_env(
      "ARTIFACT_STORE_ROOT",
      if(config_env() == :prod,
        do: "/var/lib/sprucegoose/artifacts",
        else: Path.join(System.tmp_dir!(), "sprucegoose-artifacts")
      )
    ),
  artifact_max_bytes: String.to_integer(System.get_env("ARTIFACT_MAX_BYTES", "67108864"))

if outbox_enabled? do
  config :spruce_goose, Oban,
    plugins: [
      {Oban.Plugins.Cron, crontab: SpruceGoose.Outbox.Dispatcher.cron_config()}
    ]
end

cli_service_enabled? =
  System.get_env("SPRUCE_GOOSE_CLI_SERVICE_ENABLED", "false") in ["1", "true"]

runtime_dir = System.get_env("XDG_RUNTIME_DIR", "/run/user/#{System.get_env("UID", "")}")

cli_socket_path =
  System.get_env("SPRUCE_GOOSE_CLI_SOCKET", Path.join(runtime_dir, "sprucegoose/cli.sock"))

config :spruce_goose,
  start_cli_service: cli_service_enabled?,
  cli_socket_path: cli_socket_path,
  cli_request_timeout:
    String.to_integer(System.get_env("SPRUCE_GOOSE_CLI_REQUEST_TIMEOUT_MS", "30000"))

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

  oauth_actor_bindings =
    case System.get_env("SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS") do
      value when is_binary(value) and value != "" ->
        uuid = ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

        value
        |> String.split(",", trim: true)
        |> Enum.reduce(%{}, fn entry, bindings ->
          case String.split(entry, "=", parts: 2) do
            [client_id, actor_id] ->
              if not Regex.match?(uuid, client_id) or not Regex.match?(uuid, actor_id) do
                raise "SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS entries must be canonical lowercase UUID=UUID pairs"
              end

              if Map.has_key?(bindings, client_id) do
                raise "SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS contains duplicate OAuth client ID #{client_id}"
              end

              Map.put(bindings, client_id, actor_id)

            _ ->
              raise "SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS entries must be canonical lowercase UUID=UUID pairs"
          end
        end)

      _ ->
        raise "SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS is required when MCP is enabled"
    end

  config :spruce_goose, :oauth_client_actor_bindings, oauth_actor_bindings

  config :spruce_goose, SpruceGoose.Web.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("MCP_PORT", "4000"))],
    secret_key_base: secret_key_base,
    server: true
end

if config_env() == :prod do
  expected_genesis_actor =
    case System.get_env("SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR") do
      value when is_binary(value) and value != "" -> value
      _ -> raise "SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR is required in production"
    end

  config :spruce_goose, :expected_genesis_actor, expected_genesis_actor

  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is required in production"

  ssl_flag = System.get_env("DATABASE_SSL", "true")
  ssl = ssl_flag != "false" and ssl_flag != "0"

  config :spruce_goose, SpruceGoose.Repo,
    url: database_url,
    ssl: ssl,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  config :spruce_goose,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")
end
