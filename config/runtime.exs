import Config

config :spruce_goose,
       :systemwide_sop_path,
       System.get_env(
         "SYSTEMWIDE_SOP_PATH",
         "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md"
       )

outbox_enabled? = System.get_env("OUTBOX_DISPATCHER_ENABLED", "false") in ["1", "true"]

outbox_handler =
  case System.get_env("OUTBOX_HANDLER") do
    nil ->
      nil

    name ->
      name
      |> String.trim_leading("Elixir.")
      |> String.split(".")
      |> Module.concat()
  end

if outbox_enabled? and is_nil(outbox_handler),
  do: raise("OUTBOX_HANDLER is required when OUTBOX_DISPATCHER_ENABLED is true")

config :spruce_goose,
  start_outbox_dispatcher: outbox_enabled?,
  outbox_handler: outbox_handler

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is required in production"

  ssl = System.get_env("DATABASE_SSL", "true") not in ["false", "0"]

  config :spruce_goose, SpruceGoose.Repo,
    url: database_url,
    ssl: ssl,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end
