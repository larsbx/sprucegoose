import Config

# Deterministic, non-secret test value. Never used outside the test env.
config :spruce_goose,
  token_signing_secret: "test-only-not-a-secret-token-signing",
  oauth2_issuer_url: "http://127.0.0.1:4002",
  oauth2_resource_url: "http://127.0.0.1:4002",
  oauth2_signing_secret: "test-only-not-a-secret-oauth2-signing"

config :bcrypt_elixir, log_rounds: 1

# Loopback-only test endpoint; not started unless a test asks for it.
config :spruce_goose, SpruceGoose.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false,
  secret_key_base: String.duplicate("test-only-secret-key-base-", 4)

config :spruce_goose, SpruceGoose.Repo,
  database: System.get_env("SPRUCE_GOOSE_TEST_DATABASE", "spruce_goose_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :logger, level: :warning

config :spruce_goose, Oban, testing: :manual
config :spruce_goose, :start_outbox_dispatcher, false
