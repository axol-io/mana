defmodule MerklePatriciaTree.Mixfile do
  use Mix.Project

  def project do
    [
      app: :merkle_patricia_tree,
      version: "0.2.6",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      description: "Ethereum's Merkle Patricia Trie data structure",
      package: [
        maintainers: ["Geoffrey Hayes", "Ayrat Badykov", "Mason Forest"],
        licenses: ["MIT", "Apache 2"],
        links: %{
          "GitHub" => "https://github.com/axol-io/mana/tree/master/apps/merkle_patricia_tree"
        }
      ],
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      rustler_crates: rustler_crates()
      # Temporarily disabled warnings-as-errors to allow compilation
      # elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [extra_applications: [:logger, :logger_file_backend]]
  end

  defp deps do
    [
      # External deps
      {:logger_file_backend, "~> 0.0.10"},
      {:ex_rlp, "~> 0.6"},
      {:jason, "~> 1.1"},
      {:rustler, "~> 0.29.1", runtime: false},
      # Umbrella deps
      {:exth_crypto, in_umbrella: true}
    ]
  end

  defp rustler_crates do
    [
      verkle_crypto: [path: "native/verkle_crypto", mode: rustler_mode()],
      verkle_core: [path: "native/verkle_core", mode: rustler_mode()]
    ]
  end

  defp rustler_mode do
    case Mix.env() do
      :prod -> :release
      _ -> :debug
    end
  end
end
