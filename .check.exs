[
  ## All available options with default values:

  ## It's possible to extend this configuration file to customize Mix.Check behaviour to better fit your project/team preferences.

  # if you want to add or customize tools, see Mix.Check.Tools

  # Additional test: tools: [
  #  {:ex_unit, env: %{"MIX_ENV" => "test"}}, # run in test env
  #  {:credo, env: %{"MIX_ENV" => "dev"}}, # run in dev env
  # ],

  tools: [
    ## Basic tools that work reliably
    {:formatter, command: "mix format --check-formatted"},
    {:ex_unit, env: %{"MIX_ENV" => "test", "RUSTLER_SKIP_COMPILE" => "1"}},

    ## custom tools may be added (Mix.Check.Tools behaviour)  
    {:file_naming, command: "./scripts/validate-file-naming.sh"}
  ],

  ## Enable parallel execution (boolean or pos_integer)
  parallel: true,

  ## Enable skipping tools that exit successfully (boolean)
  skipped: true,

  ## Enable exit on first failure (boolean)
  exit_on_failure: false,

  ## Set MIX_ENV for running tools (string)
  env: nil,

  ## Set application PLT file (string) - default is nil
  # plt_add_apps: [:mix, :iex, :ex_unit]

  ## Exit code when check fails - default is 1
  failure_exit_code: 1,

  ## Umbrella options
  ## Required apps - only run check if these apps have changed (list)
  umbrella: [
    required_apps: [],
    ## Skip apps - never run check for these apps (list)
    skip_apps: []
  ]
]