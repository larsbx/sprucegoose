import Config

config :spruce_goose, SpruceGoose.Repo,
  database: System.get_env("SPRUCE_GOOSE_TEST_DATABASE", "spruce_goose_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :logger, level: :warning

config :spruce_goose, Oban, testing: :manual
config :spruce_goose, :start_outbox_dispatcher, false
