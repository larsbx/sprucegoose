import Config

# Deterministic, non-secret test value. Never used outside the test env.
config :spruce_goose,
  token_signing_secret: "test-only-not-a-secret-token-signing",
  oauth2_issuer_url: "http://127.0.0.1:4002",
  oauth2_resource_url: "http://127.0.0.1:4002",
  oauth2_signing_secret: "test-only-not-a-secret-oauth2-signing"

config :bcrypt_elixir, log_rounds: 1

# The suite acts as the system: its assertions are about orchestration
# invariants, not about who is allowed to trigger them. `SpruceGoose.DataCase`
# seeds this actor with a global admin grant so policy enforcement is exercised
# on every call while the subject under test stays the behaviour, not the
# permission. `test/actors_test.exs` names restricted actors explicitly.
config :spruce_goose, :default_actor, "test-system"
config :spruce_goose, :authority_host_marker, "/nonexistent/sprucegoose-test-authority-marker"
config :spruce_goose, :allow_unbound_task_admission, true
config :spruce_goose, :allow_legacy_hierarchy_mutation, true

config :spruce_goose,
       :systemwide_sop_path,
       Path.expand("../test/fixtures/systemwide-sop.md", __DIR__)

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

# The boot-time SOP adoption check is exercised directly in
# test/sop_version_test.exs. The suite runs against a fixture SOP whose bytes
# deliberately differ from the adopted production digest, so the boot gate
# would refuse every test run.
config :spruce_goose, :verify_sop_adoption, false
