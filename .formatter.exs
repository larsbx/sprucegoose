[
  import_deps: [:ash, :ash_postgres],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "priv/repo/migrations/*.exs"
  ]
]
