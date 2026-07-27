defmodule Orchestrator.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchestrator,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Orchestrator.CLI],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Orchestrator.Application, []}
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_events, "~> 0.7.0"},
      {:ash_postgres, "~> 2.10"}
    ]
  end
end
