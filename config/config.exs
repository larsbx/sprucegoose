import Config

config :orchestrator, ash_domains: [Orchestrator.Notes, Orchestrator.Workflows]
config :orchestrator, ecto_repos: [Orchestrator.Repo]

config :orchestrator, Orchestrator.Repo,
  username: "postgres",
  hostname: "localhost",
  port: 5432,
  database: "orchestrator_dev",
  pool_size: 5

config :ash, disable_async?: true

import_config "#{config_env()}.exs"
