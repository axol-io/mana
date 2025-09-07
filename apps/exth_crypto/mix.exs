defmodule ExthCrypto.Mixfile do
  use Mix.Project

  def project do
    [
      app: :exth_crypto,
      version: "0.1.4",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      description: "Mana's Crypto Suite.",
      package: [
        maintainers: ["Geoffrey Hayes", "Mason Fischer"]
      ],
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Configure Rustler NIF compilation
      rustler_crates: [
        kzg_nif: [
          path: "native/kzg_nif",
          mode: if(Mix.env() == :prod, do: :release, else: :debug)
        ]
      ]
    ]
  end

  def application do
    [
      mod: {ExthCrypto.Application, []},
      extra_applications: [:logger, :logger_file_backend, :crypto]
    ]
  end

  defp deps do
    [
      # External deps
      {:logger_file_backend, "~> 0.0.10"},
      {:libsecp256k1, "~> 0.1.10"},
      # Pure Elixir Keccak implementation (Erlang 27 compatible)
      {:ex_sha3, "~> 0.1.4"},
      # {:keccakf1600, "~> 2.1", hex: :keccakf1600_orig},  # Temporarily disabled due to Erlang 27 compatibility issues
      {:binary, "~> 0.0.4"},
      # For HSM configuration JSON handling
      {:jason, "~> 1.4"},
      # KZG NIF dependencies
      {:rustler, "~> 0.29.1"},
      # Property-based testing
      {:stream_data, "~> 0.6", only: :test}
    ]
  end
end
