import Config

config :spruce_goose,
  ash_domains: [SpruceGoose.Notes, SpruceGoose.Workflows, SpruceGoose.Knowledge.Domain]

config :spruce_goose, ecto_repos: [SpruceGoose.Repo]

config :spruce_goose, SpruceGoose.Repo,
  username: "postgres",
  hostname: "localhost",
  port: 5432,
  database: "spruce_goose_dev",
  pool_size: 5

config :ash, disable_async?: true

config :spruce_goose, Oban,
  repo: SpruceGoose.Repo,
  queues: [outbox: 1]

config :spruce_goose, :start_outbox_dispatcher, false
config :spruce_goose, :outbox_handler, nil

# Delivery is deliberately opt-in. Runtime configuration must name a module
# implementing deliver/1; enabling without one fails closed in runtime.exs.

config :spruce_goose,
       :systemwide_sop_path,
       "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md"

import_config "#{config_env()}.exs"
