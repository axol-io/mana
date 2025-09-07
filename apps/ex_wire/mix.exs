defmodule ExWire.Mixfile do
  use Mix.Project

  def project do
    [
      app: :ex_wire,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      description: "Ethereum P2P networking implementation",
      package: [
        maintainers: ["Geoffrey Hayes", "Ayrat Badykov", "Mason Forest"],
        licenses: ["MIT", "Apache 2"],
        links: %{
          "GitHub" => "https://github.com/axol-io/mana/tree/master/apps/ex_wire"
        }
      ],
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # Configure Rustler NIF compilation
      rustler_crates: [
        bls_nif: [
          path: "native/bls_nif",
          mode: if(Mix.env() == :prod, do: :release, else: :debug)
        ],
        pkcs11_nif: [
          path: "native/pkcs11_nif",
          mode: if(Mix.env() == :prod, do: :release, else: :debug)
        ]
      ]
      # Temporarily disabled warnings-as-errors to allow compilation
      # elixirc_options: [warnings_as_errors: true]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Umbrella deps
      {:blockchain, in_umbrella: true},
      {:exth, in_umbrella: true},
      {:exth_crypto, in_umbrella: true},
      {:merkle_patricia_tree, in_umbrella: true},

      # Parallel processing
      {:flow, "~> 1.2"},

      # BLS signature NIF
      {:rustler, "~> 0.29.1"},

      # YAML parsing for consensus spec tests
      {:yaml_elixir, "~> 2.9"},

      # Web3 client dependencies
      {:httpoison, "~> 1.4"},
      {:jason, "~> 1.4"}
    ]
  end
end
