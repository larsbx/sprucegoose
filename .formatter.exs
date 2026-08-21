[
  import_deps: [:ash_authentication_oauth2_server, :ash_authentication, :ash, :ash_postgres],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "priv/repo/migrations/*.exs"
  ],
  plugins: [Spark.Formatter]
]
