defmodule History.MixProject do
  use Mix.Project

  def project do
    [
      app: :history,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Stateless Ethereum history node - efficient log indexing without EVM",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {History.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:blockchain, in_umbrella: true},
      {:ex_wire, in_umbrella: true},
      {:exth, in_umbrella: true},
      {:exth_crypto, in_umbrella: true},
      {:merkle_patricia_tree, in_umbrella: true},
      {:ex_rlp, "~> 0.6"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:cubdb, "~> 2.0"},
      {:cowboy, "~> 2.10"},
      {:plug_cowboy, "~> 2.6"},
      {:phoenix_pubsub, "~> 2.1"}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0", "MIT"],
      links: %{"GitHub" => "https://github.com/axol-io/mana"}
    ]
  end
end
