import Config

config :spruce_goose, ash_domains: [SpruceGoose.Notes, SpruceGoose.Workflows]
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

config :spruce_goose, :start_outbox_dispatcher, true

import_config "#{config_env()}.exs"
