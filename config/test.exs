import Config

config :spruce_goose, SpruceGoose.Repo,
  database: System.get_env("SPRUCE_GOOSE_TEST_DATABASE", "orchestrator_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :logger, level: :warning
