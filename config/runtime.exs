import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is required in production"

  ssl = System.get_env("DATABASE_SSL", "true") not in ["false", "0"]

  config :orchestrator, Orchestrator.Repo,
    url: database_url,
    ssl: ssl,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end
