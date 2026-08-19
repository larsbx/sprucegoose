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
        path: System.get_env("SPRUCE_GOOSE_ESCRIPT_PATH", "sprucegoose")
      ],
      test_ignore_filters: [~r|^test/fixtures/|],
      releases: releases(),
      deps: deps()
    ]
  end

  # Minimal release declaration only. Without it `mix release spruce_goose`
  # aborts with "Unknown release", so governed provenance can never reach the
  # success path that embeds provenance into an assembled release.
  #
  # This declares release identity and nothing else: the application is named
  # explicitly as :permanent rather than inferred. Output path, ERTS inclusion,
  # cookies, runtime config providers, overlays, and every other deployment
  # concern are deliberately absent. scripts/build-governed-release supplies
  # --path per invocation so the release never materializes inside the
  # repository, which would falsify clean-source classification.
  #
  # Full CI/CD release configuration is scoped to successor task
  # tsk-20260813T140419Z-d8dbffc5 and must not be added here.
  defp releases do
    [
      spruce_goose: [
        applications: [spruce_goose: :permanent]
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
      {:picosat_elixir, "~> 0.2"},
      {:ash, "~> 3.0"},
      {:ash_events, "~> 0.7.0"},
      {:ash_postgres, "~> 2.10"},
      {:ash_ai, "~> 0.8"},
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
