defmodule Mana.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: [
        :logger,
        :logger_file_backend,
        :common,
        :blockchain,
        :cli,
        :evm,
        :ex_wire,
        :exth,
        :exth_crypto,
        :merkle_patricia_tree,
        :jsonrpc2
      ],
      elixirc_options: [warnings_as_errors: false],
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      dialyzer: [
        flags: [:underspecs, :unknown, :unmatched_returns],
        ignore_warnings: ".dialyzer.ignore-warnings",
        plt_add_apps: [:mix, :iex, :ex_unit, :ranch, :plug, :hackney, :jason, :websockex, :cowboy]
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ],
      deps: deps()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      {:ex_rlp, "~> 0.6"},
      {:ex_doc, "~> 0.19", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0.0-rc.4", only: [:dev, :test], runtime: false},
      {:ethereumex, "~> 0.5.1"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.0.0-rc1", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 0.6", only: [:dev, :test]},
      {:artificery, "~> 0.1.0"},
      {:logger_file_backend, "~> 0.0.10"},
      {:ssl_verify_fun, "~> 1.1.7", override: true},
      # Fixed version of mix_erlang_tasks to avoid broken hex package
      {:mix_erlang_tasks, "0.1.0", path: "vendor/mix_erlang_tasks", override: true}
    ]
  end
end
