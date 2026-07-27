import Config

config :orchestrator, Orchestrator.Repo,
  database: System.get_env("ORCHESTRATOR_TEST_DATABASE", "orchestrator_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :logger, level: :warning
