defmodule Common.MixProject do
  use Mix.Project

  def project do
    [
      app: :common,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :telemetry]
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:benchee, "~> 1.0", only: [:dev, :test]},
      {:jason, "~> 1.4"}
    ]
  end
end
