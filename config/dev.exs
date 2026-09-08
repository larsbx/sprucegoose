import Config

# No secrets in version control.
#
# The ash_authentication / oauth2_server installers write literal dev secrets
# here by default. That is not acceptable in this repository, so the values are
# read from the environment instead and fall back to clearly-marked
# non-production development placeholders.
#
# For a real local OAuth flow, export these before starting the endpoint:
#
#     export TOKEN_SIGNING_SECRET=...
#     export OAUTH2_SIGNING_SECRET=...
#
# Generate with: mix phx.gen.secret
#
# The URLs stay loopback-only by design; the MCP endpoint is not exposed
# off-host without a separate, governed security decision.

config :spruce_goose,
  token_signing_secret:
    System.get_env("TOKEN_SIGNING_SECRET", "dev-only-placeholder-not-a-secret-token-signing"),
  oauth2_issuer_url: System.get_env("OAUTH2_ISSUER_URL", "http://127.0.0.1:4000"),
  oauth2_resource_url: System.get_env("OAUTH2_RESOURCE_URL", "http://127.0.0.1:4000"),
  oauth2_signing_secret:
    System.get_env("OAUTH2_SIGNING_SECRET", "dev-only-placeholder-not-a-secret-oauth2-signing")

# Dev has no governed Systemwide SOP, so the boot-time adoption check has
# nothing real to compare against. Production and any deployment that serves
# requests keeps it on; see SpruceGoose.SopGate.verify_adoption/0.
config :spruce_goose, :verify_sop_adoption, false
