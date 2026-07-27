import Config

config :spruce_goose, ash_domains: [SpruceGoose.Notes, SpruceGoose.Workflows]
config :spruce_goose, ecto_repos: [SpruceGoose.Repo]

config :spruce_goose, SpruceGoose.Repo,
  username: "postgres",
  hostname: "localhost",
  port: 5432,
  # Compatibility: preserve the authoritative cutover database in place.
  database: "orchestrator_dev",
  pool_size: 5

config :ash, disable_async?: true

import_config "#{config_env()}.exs"
