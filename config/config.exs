import Config

config :spark,
  formatter: ["Ash.Resource": [section_order: [:authentication, :token, :user_identity]]]

config :spruce_goose,
  ash_domains: [
    SpruceGoose.Accounts,
    SpruceGoose.Actors,
    SpruceGoose.Notes,
    SpruceGoose.Workflows,
    SpruceGoose.Knowledge.Domain
  ]

config :spruce_goose, ecto_repos: [SpruceGoose.Repo]

# The actor a request acts as when it names none. Deliberately nil: an
# unconfigured deployment refuses rather than assuming an identity. Set it only
# where one known party drives the CLI.
config :spruce_goose, :default_actor, nil

config :spruce_goose, SpruceGoose.Repo,
  username: "postgres",
  hostname: "localhost",
  port: 5432,
  database: "spruce_goose_dev",
  pool_size: 5

config :ash, disable_async?: true

config :phoenix, :json_library, Jason

# The MCP/OAuth endpoint is opt-in. SpruceGoose stays CLI-first: nothing binds
# a port unless SPRUCE_GOOSE_MCP_ENABLED is set (see config/runtime.exs).
config :spruce_goose, :start_web_endpoint, false

# Loopback-only by default. Exposing this endpoint off-host is a separate,
# governed security decision.
config :spruce_goose, SpruceGoose.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "127.0.0.1"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: false,
  render_errors: [formats: [json: SpruceGoose.Web.ErrorJSON], layout: false]

config :spruce_goose, Oban,
  repo: SpruceGoose.Repo,
  queues: [outbox: 1]

config :spruce_goose, :start_outbox_dispatcher, false
config :spruce_goose, :outbox_handler, nil
config :spruce_goose, :start_cli_service, false
config :spruce_goose, :cli_socket_path, nil
config :spruce_goose, :cli_request_timeout, 30_000

# Delivery is deliberately opt-in. Runtime configuration must name a module
# implementing deliver/1; enabling without one fails closed in runtime.exs.

config :spruce_goose,
       :systemwide_sop_path,
       "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md"

import_config "#{config_env()}.exs"
