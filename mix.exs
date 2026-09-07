defmodule SpruceGoose.MixProject do
  use Mix.Project

  def project do
    [
      app: :spruce_goose,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: [
        main_module: SpruceGoose.CLI,
        name: "sprucegoose",
        path: System.get_env("SPRUCE_GOOSE_ESCRIPT_PATH", "sprucegoose-direct")
      ],
      test_ignore_filters: [~r|^test/fixtures/|],
      releases: releases(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # The evidence integration lane is deliberately outside default `mix test`
  # discovery: test/test_helper.exs puts the Repo into Sandbox :manual mode,
  # and a sandbox transaction cannot carry the REPEATABLE READ, READ ONLY
  # semantics this lane exists to observe. It runs its own ExUnit against
  # disposable databases supplied by the caller.
  defp aliases do
    [
      "test.evidence_integration": [
        "run --no-start test/evidence/integration_runner.exs"
      ]
    ]
  end

  # Keep the runtime self-contained, preserve provenance chunks, and evaluate
  # config/runtime.exs on the destination. The governed builder supplies the
  # external --path and the destination supplies secrets through its environment.
  defp releases do
    [
      spruce_goose: [
        applications: [spruce_goose: :permanent],
        include_erts: true,
        runtime_config_path: "config/runtime.exs",
        strip_beams: false
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SpruceGoose.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.12"},
      {:picosat_elixir, "~> 0.2"},
      {:ash, "~> 3.0"},
      {:ash_events, "~> 0.7.0"},
      {:ash_postgres, "~> 2.10"},
      {:ash_ai, "~> 1.0"},
      {:ash_authentication, "~> 5.0-rc"},
      {:ash_authentication_oauth2_server, "~> 0.3"},
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      # Present transitively via llm_db; named directly because the revise
      # verb parses TOML and must not depend on another package's dep tree.
      {:toml, "~> 0.7"},
      {:b3, "~> 0.2.0"},
      {:oban, "~> 2.19"},
      {:igniter, "~> 0.6", only: [:dev, :test]}
    ]
  end
end
