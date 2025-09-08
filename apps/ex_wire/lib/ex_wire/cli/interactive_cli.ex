defmodule ExWire.CLI.InteractiveCLI do
  @moduledoc """
  Enhanced interactive CLI for Mana-Ethereum with world-class developer experience.

  Provides an advanced interactive shell with:
  - Syntax highlighting and auto-completion
  - Real-time blockchain state inspection
  - Transaction debugging and tracing
  - Smart contract interaction
  - Performance monitoring
  - Multi-datacenter management
  - CRDT consensus visualization

  ## Features

  - **Interactive REPL**: IEx-style interface with blockchain context
  - **Auto-completion**: Smart completion for addresses, transaction hashes, blocks
  - **Syntax highlighting**: Color-coded output for better readability  
  - **Real-time updates**: Live blockchain state changes
  - **Context switching**: Switch between mainnet, testnet, local dev
  - **History**: Command history with search and replay
  - **Pipe operations**: Unix-style command chaining
  - **Export capabilities**: Export data to JSON, CSV, etc.

  ## Usage

      # Start interactive CLI
      iex> ExWire.CLI.InteractiveCLI.start()
      
      mana> help
      mana> block latest
      mana> account 0x1234... | balance
      mana> tx 0xabcd... | debug | trace
  """

  use GenServer
  require Logger

  alias ExWire.CLI.{
    Commands,
    Formatter,
    AutoComplete,
    HistoryManager,
    ContextManager
  }

  @type cli_state :: %{
          # :mainnet | :testnet | :dev | :multi_dc
          context: atom(),
          history: list(),
          auto_complete_cache: map(),
          active_subscriptions: [pid()],
          formatter_options: map(),
          debug_mode: boolean(),
          performance_monitoring: boolean()
        }

  defstruct [
    :context,
    :history_manager,
    :auto_complete,
    :context_manager,
    :formatter,
    :command_registry,
    :subscription_manager,
    :state
  ]

  @name __MODULE__

  # ANSI color codes for enhanced output
  @colors %{
    # Cyan
    primary: "\e[36m",
    # Magenta  
    secondary: "\e[35m",
    # Green
    success: "\e[32m",
    # Yellow
    warning: "\e[33m",
    # Red
    error: "\e[31m",
    # Blue
    info: "\e[34m",
    # Reset
    reset: "\e[0m",
    # Bold
    bold: "\e[1m",
    # Dim
    dim: "\e[2m"
  }

  @banner """
  #{@colors.primary}#{@colors.bold}
  ╔═══════════════════════════════════════════════════════════════╗
  ║                    MANA-ETHEREUM CLI v3.0                    ║
  ║           World's First CRDT-Based Ethereum Client           ║
  ║                                                               ║
  ║  • Multi-datacenter operation    • Zero-coordination consensus║
  ║  • Partition tolerance          • Active-active replication  ║  
  ║  • Geographic distribution      • Automatic conflict resolution║
  ╚═══════════════════════════════════════════════════════════════╝
  #{@colors.reset}

  #{@colors.info}Type 'help' for available commands, 'quit' to exit#{@colors.reset}
  """

  # Public API

  @spec start(Keyword.t()) :: :ok
  def start(opts \\ []) do
    context = Keyword.get(opts, :context, :dev)
    debug_mode = Keyword.get(opts, :debug, false)

    case GenServer.start_link(__MODULE__, [context: context, debug: debug_mode], name: @name) do
      {:ok, _pid} ->
        IO.puts(@banner)
        start_interactive_loop()

      {:error, {:already_started, _pid}} ->
        IO.puts("#{@colors.info}CLI already running. Type 'help' for commands.#{@colors.reset}")
        start_interactive_loop()

      {:error, _reason} ->
        IO.puts("#{@colors.error}Failed to start CLI: #{inspect(reason)}#{@colors.reset}")
    end
  end

  @spec execute_command(String.t()) :: term()
  def execute_command(command_line) do
    GenServer.call(@name, {:execute_command, command_line})
  end

  @spec get_auto_completions(String.t()) :: [String.t()]
  def get_auto_completions(partial_command) do
    GenServer.call(@name, {:auto_complete, partial_command})
  end

  @spec switch_context(atom()) :: :ok
  def switch_context(new_context) do
    GenServer.cast(@name, {:switch_context, new_context})
  end

  @spec toggle_debug_mode() :: :ok
  def toggle_debug_mode() do
    GenServer.cast(@name, :toggle_debug_mode)
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    context = Keyword.get(opts, :context, :dev)
    debug_mode = Keyword.get(opts, :debug, false)

    # Initialize supporting modules
    {:ok, history_manager} = HistoryManager.start_link()
    {:ok, auto_complete} = AutoComplete.start_link()
    {:ok, context_manager} = ContextManager.start_link(context)
    {:ok, formatter} = Formatter.start_link()

    state = %__MODULE__{
      context: context,
      history_manager: history_manager,
      auto_complete: auto_complete,
      context_manager: context_manager,
      formatter: formatter,
      command_registry: build_command_registry(),
      subscription_manager: nil,
      state: %{
        context: context,
        history: [],
        auto_complete_cache: %{},
        active_subscriptions: [],
        formatter_options: %{colors: true, compact: false},
        debug_mode: debug_mode,
        performance_monitoring: false
      }
    }

    Logger.info("[InteractiveCLI] Started with context: #{context}")

    {:ok, _state}
  end

  @impl GenServer
  def handle_call({:execute_command, command_line}, _from, _state) do
    trimmed_command = String.trim(command_line)

    # Skip empty commands
    if trimmed_command == "" do
      {:reply, :ok, state}
    else
      # Add to history
      HistoryManager.add_command(state.history_manager, trimmed_command)

      # Parse and execute command
      result = parse_and_execute(trimmed_command, state)

      {:reply, result, state}
    end
  end

  @impl GenServer
  def handle_call({:auto_complete, partial_command}, _from, _state) do
    completions =
      AutoComplete.get_completions(state.auto_complete, partial_command, state.context)

    {:reply, completions, state}
  end

  @impl GenServer
  def handle_cast({:switch_context, new_context}, _state) do
    Logger.info("[InteractiveCLI] Switching context: #{state.context} -> #{new_context}")

    ContextManager.switch_context(state.context_manager, new_context)

    new_state = %{state | context: new_context, state: %{state.state | context: new_context}}

    IO.puts("#{@colors.success}Switched to #{new_context} context#{@colors.reset}")

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast(:toggle_debug_mode, _state) do
    new_debug_mode = not state.state.debug_mode

    new_state = %{state | state: %{state.state | debug_mode: new_debug_mode}}

    status = if new_debug_mode, do: "enabled", else: "disabled"
    IO.puts("#{@colors.info}Debug mode #{status}#{@colors.reset}")

    {:noreply, new_state}
  end

  # Private functions

  defp start_interactive_loop() do
    spawn(fn -> interactive_loop() end)
    :ok
  end

  defp interactive_loop() do
    try do
      # Get current context for prompt
      context = GenServer.call(@name, :get_context)
      context_color = get_context_color(context)

      # Display prompt
      prompt = "#{context_color}mana:#{context}#{@colors.reset}> "

      case IO.gets(prompt) do
        :eof ->
          IO.puts("\n#{@colors.info}Goodbye!#{@colors.reset}")
          :ok

        {:error, _reason} ->
          IO.puts("#{@colors.error}Input error: #{inspect(reason)}#{@colors.reset}")
          interactive_loop()

        command_line when is_binary(command_line) ->
          command_line = String.trim(command_line)

          case command_line do
            "" ->
              interactive_loop()

            "quit" <> _ ->
              IO.puts("#{@colors.info}Goodbye!#{@colors.reset}")
              :ok

            "exit" <> _ ->
              IO.puts("#{@colors.info}Goodbye!#{@colors.reset}")
              :ok

            _ ->
              execute_command(command_line)
              interactive_loop()
          end
      end
    rescue
      e ->
        IO.puts("#{@colors.error}CLI error: #{inspect(e)}#{@colors.reset}")
        interactive_loop()
    end
  end

  defp parse_and_execute(command_line, _state) do
    # Support pipe operations: command1 | command2 | command3
    commands =
      command_line
      |> String.split("|")
      |> Enum.map(&String.trim/1)

    try do
      execute_pipeline(commands, nil, state)
    rescue
      e ->
        formatted_error = Formatter.format_error(state.formatter, e)
        IO.puts(formatted_error)
        {:error, e}
    end
  end

  defp execute_pipeline([], result, _state), do: result

  defp execute_pipeline([command | rest], input, _state) do
    # Parse command and arguments
    [cmd | args] = String.split(command, " ", trim: true)

    # Execute command
    result =
      case Map.get(state.command_registry, cmd) do
        nil ->
          IO.puts("#{@colors.error}Unknown command: #{cmd}#{@colors.reset}")
          IO.puts("#{@colors.info}Type 'help' to see available commands#{@colors.reset}")
          {:error, :unknown_command}

        command_module ->
          command_module.execute(args, input, state)
      end

    # Continue pipeline with result as input to next command
    case result do
      {:error, _} -> result
      _ -> execute_pipeline(rest, result, state)
    end
  end

  defp build_command_registry() do
    %{
      # Core blockchain commands
      "help" => Commands.Help,
      "status" => Commands.Status,
      "block" => Commands.Block,
      "blocks" => Commands.Blocks,
      "tx" => Commands.Transaction,
      "account" => Commands.Account,
      "balance" => Commands.Balance,
      "nonce" => Commands.Nonce,

      # Developer tools
      "debug" => Commands.Debug,
      "trace" => Commands.Trace,
      "profile" => Commands.Profile,
      "gas" => Commands.Gas,
      "contract" => Commands.Contract,
      "call" => Commands.Call,

      # Multi-datacenter and CRDT
      "consensus" => Commands.Consensus,
      "replicas" => Commands.Replicas,
      "datacenter" => Commands.Datacenter,
      "crdt" => Commands.CRDT,
      "sync" => Commands.Sync,

      # Utility commands
      "context" => Commands.Context,
      "history" => Commands.History,
      "export" => Commands.Export,
      "import" => Commands.Import,
      "monitor" => Commands.Monitor,
      "logs" => Commands.Logs,

      # Network and peers
      "peers" => Commands.Peers,
      "network" => Commands.Network,
      "routing" => Commands.Routing,

      # Performance and diagnostics
      "perf" => Commands.Performance,
      "memory" => Commands.Memory,
      "cpu" => Commands.CPU,
      "disk" => Commands.Disk
    }
  end

  # Red for mainnet (be careful!)
  defp get_context_color(:mainnet), do: @colors.error
  # Yellow for testnet
  defp get_context_color(:testnet), do: @colors.warning
  # Green for dev
  defp get_context_color(:dev), do: @colors.success
  # Cyan for multi-datacenter
  defp get_context_color(:multi_dc), do: @colors.primary
  # Blue for others
  defp get_context_color(_), do: @colors.info
end

# Supporting modules for the CLI

defmodule ExWire.CLI.HistoryManager do
  @moduledoc "Manages command history with search and replay capabilities"

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def add_command(pid, command) do
    GenServer.cast(pid, {:add_command, command})
  end

  def get_history(pid, limit \\ 50) do
    GenServer.call(pid, {:get_history, limit})
  end

  def search_history(pid, pattern) do
    GenServer.call(pid, {:search_history, pattern})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{history: [], max_size: 1000}}
  end

  @impl GenServer
  def handle_cast({:add_command, command}, _state) do
    new_history =
      [command | state.history]
      |> Enum.take(state.max_size)

    {:noreply, %{state | history: new_history}}
  end

  @impl GenServer
  def handle_call({:get_history, limit}, _from, _state) do
    history = Enum.take(state.history, limit)
    {:reply, history, state}
  end

  @impl GenServer
  def handle_call({:search_history, pattern}, _from, _state) do
    matches =
      state.history
      |> Enum.filter(&String.contains?(&1, pattern))
      |> Enum.take(20)

    {:reply, matches, state}
  end
end

defmodule ExWire.CLI.AutoComplete do
  @moduledoc "Provides intelligent auto-completion for commands and parameters"

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def get_completions(pid, partial_command, context) do
    GenServer.call(pid, {:get_completions, partial_command, context})
  end

  @impl GenServer
  def init(_opts) do
    # Pre-populate with common commands and blockchain data
    state = %{
      commands: [
        "help",
        "status",
        "block",
        "blocks",
        "tx",
        "account",
        "balance",
        "nonce",
        "debug",
        "trace",
        "profile",
        "gas",
        "contract",
        "call",
        "consensus",
        "replicas",
        "datacenter",
        "crdt",
        "sync",
        "context",
        "history",
        "export",
        "import",
        "monitor",
        "logs",
        "peers",
        "network",
        "routing",
        "perf",
        "memory",
        "cpu",
        "disk"
      ],
      recent_addresses: [],
      recent_tx_hashes: [],
      recent_block_hashes: []
    }

    {:ok, _state}
  end

  @impl GenServer
  def handle_call({:get_completions, partial_command, _context}, _from, _state) do
    completions =
      state.commands
      |> Enum.filter(&String.starts_with?(&1, partial_command))
      |> Enum.sort()

    {:reply, completions, state}
  end
end

defmodule ExWire.CLI.ContextManager do
  @moduledoc "Manages different CLI contexts (mainnet, testnet, dev, multi-datacenter)"

  use GenServer

  def start_link(initial_context) do
    GenServer.start_link(__MODULE__, initial_context)
  end

  def switch_context(pid, new_context) do
    GenServer.cast(pid, {:switch_context, new_context})
  end

  def get_context(pid) do
    GenServer.call(pid, :get_context)
  end

  @impl GenServer
  def init(initial_context) do
    {:ok, %{current_context: initial_context}}
  end

  @impl GenServer
  def handle_cast({:switch_context, new_context}, _state) do
    {:noreply, %{state | current_context: new_context}}
  end

  @impl GenServer
  def handle_call(:get_context, _from, _state) do
    {:reply, state.current_context, state}
  end
end

defmodule ExWire.CLI.Formatter do
  @moduledoc "Formats output with colors, tables, and structured data"

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def format_block(pid, block) do
    GenServer.call(pid, {:format_block, block})
  end

  def format_transaction(pid, transaction) do
    GenServer.call(pid, {:format_transaction, transaction})
  end

  def format_error(pid, error) do
    GenServer.call(pid, {:format_error, error})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{colors_enabled: true}}
  end

  @impl GenServer
  def handle_call({:format_block, block}, _from, _state) do
    formatted = """
    \e[36m━━━ BLOCK ##{block.header.number} ━━━\e[0m
    \e[32mHash:\e[0m     #{format_hash(block.header.hash)}
    \e[32mParent:\e[0m   #{format_hash(block.header.parent_hash)}
    \e[32mTimestamp:\e[0m #{format_timestamp(block.header.timestamp)}
    \e[32mGas Used:\e[0m  #{block.header.gas_used} / #{block.header.gas_limit}
    \e[32mTxs:\e[0m      #{length(block.transactions)}
    """

    {:reply, formatted, state}
  end

  @impl GenServer
  def handle_call({:format_transaction, tx}, _from, _state) do
    formatted = """
    \e[35m━━━ TRANSACTION ━━━\e[0m
    \e[32mHash:\e[0m     #{format_hash(tx.hash)}
    \e[32mFrom:\e[0m     #{format_address(tx.from)}
    \e[32mTo:\e[0m       #{format_address(tx.to)}
    \e[32mValue:\e[0m    #{format_wei(tx.value)} ETH
    \e[32mGas:\e[0m      #{tx.gas_limit} @ #{tx.gas_price} gwei
    \e[32mNonce:\e[0m    #{tx.nonce}
    """

    {:reply, formatted, state}
  end

  @impl GenServer
  def handle_call({:format_error, error}, _from, _state) do
    formatted = "\e[31m✗ Error: #{inspect(error)}\e[0m"
    {:reply, formatted, state}
  end

  defp format_hash(hash) when is_binary(hash) do
    "0x" <> Base.encode16(hash, case: :lower)
  end

  defp format_address(address) when is_binary(address) do
    "0x" <> Base.encode16(address, case: :lower)
  end

  defp format_wei(wei) when is_integer(wei) do
    :erlang.float_to_binary(wei / 1_000_000_000_000_000_000, decimals: 6)
  end

  defp format_timestamp(timestamp) when is_integer(timestamp) do
    DateTime.from_unix!(timestamp) |> DateTime.to_string()
  end
end
