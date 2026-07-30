defmodule SpruceGoose.MixProject do
  use Mix.Project

  def project do
    [
      app: :spruce_goose,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: SpruceGoose.CLI, name: "sprucegoose"],
      test_ignore_filters: [~r|^test/fixtures/|],
      deps: deps()
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
      {:ash, "~> 3.0"},
      {:ash_events, "~> 0.7.0"},
      {:ash_postgres, "~> 2.10"},
      {:b3, "~> 0.2.0"},
      {:oban, "~> 2.19"}
    ]
  end
end
