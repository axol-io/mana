defmodule ExWire.Layer2.NetworkInterface do
  @moduledoc """
  Network interface for connecting to major Layer 2 networks.
  Provides unified connection management for Optimism, Arbitrum, and zkSync Era.
  """

  use GenServer
  require Logger

  alias ExWire.Layer2.{OptimisticRollup, ZKRollup, CrossLayerBridge}

  @supported_networks ~w(optimism_mainnet arbitrum_mainnet zksync_era_mainnet)a

  defstruct [
    :network_name,
    :network_type,
    :config,
    :l1_connection,
    :l2_connection,
    :rollup_pid,
    :bridge_pid,
    :status,
    :last_sync_block,
    :metrics
  ]

  ## Client API

  @doc """
  Starts a connection to a Layer 2 network.
  """
  def start_link(network_name, _config \\ %{}) do
    GenServer.start_link(__MODULE__, {network_name, config}, name: via_tuple(network_name))
  end

  @doc """
  Connects to the specified Layer 2 network.
  """
  def connect(network_name) do
    GenServer.call(via_tuple(network_name), :connect, 30_000)
  end

  @doc """
  Disconnects from the Layer 2 network.
  """
  def disconnect(network_name) do
    GenServer.call(via_tuple(network_name), :disconnect)
  end

  @doc """
  Gets the current status of the L2 network connection.
  """
  def status(network_name) do
    GenServer.call(via_tuple(network_name), :status)
  end

  @doc """
  Submits a transaction to the L2 network.
  """
  def submit_transaction(network_name, transaction) do
    GenServer.call(via_tuple(network_name), {:submit_transaction, transaction})
  end

  @doc """
  Queries the L2 state for a specific account or contract.
  """
  def query_state(network_name, address, slot \\ nil) do
    GenServer.call(via_tuple(network_name), {:query_state, address, slot})
  end

  @doc """
  Initiates a withdrawal from L2 to L1.
  """
  def initiate_withdrawal(network_name, withdrawal_params) do
    GenServer.call(via_tuple(network_name), {:initiate_withdrawal, withdrawal_params})
  end

  @doc """
  Gets network metrics and performance statistics.
  """
  def get_metrics(network_name) do
    GenServer.call(via_tuple(network_name), :get_metrics)
  end

  @doc """
  Lists all supported Layer 2 networks.
  """
  def supported_networks, do: @supported_networks

  ## Server Callbacks

  @impl true
  def init({network_name, _config}) do
    if network_name not in @supported_networks do
      {:stop, {:unsupported_network, network_name}}
    else
      network_config = load_network_config(network_name, config)

      state = %__MODULE__{
        network_name: network_name,
        network_type: network_config.network_type,
        config: network_config,
        status: :disconnected,
        last_sync_block: 0,
        metrics: init_metrics()
      }

      Logger.info("Initialized L2 network interface for #{network_name}")
      {:ok, _state}
    end
  end

  @impl true
  def handle_call(:connect, _from, _state) do
    case establish_connections(state) do
      {:ok, updated_state} ->
        {:ok, rollup_state} = start_rollup_handler(updated_state)
        {:ok, bridge_state} = start_bridge_handler(rollup_state)

        final_state = %{bridge_state | status: :connected}
        Logger.info("Connected to #{final_state.network_name}")

        {:reply, {:ok, :connected}, final_state}

      {:error, _reason} ->
        Logger.error("Failed to connect to #{state.network_name}: #{inspect(reason)}")
        {:reply, {:error, _reason}, state}
    end
  end

  @impl true
  def handle_call(:disconnect, _from, _state) do
    updated_state = cleanup_connections(state)
    Logger.info("Disconnected from #{state.network_name}")
    {:reply, :ok, %{updated_state | status: :disconnected}}
  end

  @impl true
  def handle_call(:status, _from, _state) do
    status_info = %{
      network: state.network_name,
      type: state.network_type,
      status: state.status,
      last_sync_block: state.last_sync_block,
      l1_connected: state.l1_connection != nil,
      l2_connected: state.l2_connection != nil,
      rollup_active: state.rollup_pid != nil,
      bridge_active: state.bridge_pid != nil
    }

    {:reply, status_info, state}
  end

  @impl true
  def handle_call({:submit_transaction, transaction}, _from, _state) do
    case state.status do
      :connected ->
        result = submit_to_l2(state, transaction)
        update_metrics(state, :transaction_submitted)
        {:reply, result, _state}

      _ ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call({:query_state, address, slot}, _from, _state) do
    case state.status do
      :connected ->
        result = query_l2_state(state, address, slot)
        update_metrics(state, :state_query)
        {:reply, result, _state}

      _ ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call({:initiate_withdrawal, _params}, _from, _state) do
    case state.status do
      :connected ->
        result = initiate_l2_withdrawal(state, _params)
        update_metrics(state, :withdrawal_initiated)
        {:reply, result, _state}

      _ ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call(:get_metrics, _from, _state) do
    {:reply, state.metrics, state}
  end

  @impl true
  def handle_info({:sync_update, block_number}, _state) do
    updated_state = %{state | last_sync_block: block_number}
    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:rollup_event, event}, _state) do
    Logger.debug("Received rollup event: #{inspect(event)}")
    update_metrics(state, :rollup_event_received)
    {:noreply, state}
  end

  @impl true
  def handle_info({:bridge_event, event}, _state) do
    Logger.debug("Received bridge event: #{inspect(event)}")
    update_metrics(state, :bridge_event_received)
    {:noreply, state}
  end

  ## Private Functions

  defp via_tuple(network_name) do
    {:via, Registry, {ExWire.Layer2.NetworkRegistry, network_name}}
  end

  defp load_network_config(network_name, override_config) do
    config_file = "config/layer2/#{network_name}.yaml"

    base_config =
      case File.read(config_file) do
        {:ok, content} ->
          YamlElixir.read_from_string!(content)

        {:error, _} ->
          Logger.warning("Config file not found: #{config_file}, using defaults")
          default_config(network_name)
      end

    # Deep merge with override config
    deep_merge(base_config, override_config)
  end

  defp default_config(:optimism_mainnet) do
    %{
      "name" => "optimism_mainnet",
      "network_type" => "optimistic_rollup",
      "chain_id" => 10,
      "l1_network" => %{"chain_id" => 1},
      "l2_network" => %{"chain_id" => 10}
    }
  end

  defp default_config(:arbitrum_mainnet) do
    %{
      "name" => "arbitrum_mainnet",
      "network_type" => "optimistic_rollup",
      "chain_id" => 42161,
      "l1_network" => %{"chain_id" => 1},
      "l2_network" => %{"chain_id" => 42161}
    }
  end

  defp default_config(:zksync_era_mainnet) do
    %{
      "name" => "zksync_era_mainnet",
      "network_type" => "zk_rollup",
      "chain_id" => 324,
      "l1_network" => %{"chain_id" => 1},
      "l2_network" => %{"chain_id" => 324}
    }
  end

  defp establish_connections(_state) do
    with {:ok, l1_conn} <- connect_to_l1(state.config),
         {:ok, l2_conn} <- connect_to_l2(state.config) do
      updated_state = %{state | l1_connection: l1_conn, l2_connection: l2_conn}
      {:ok, updated_state}
    else
      {:error, _reason} -> {:error, _reason}
    end
  end

  defp connect_to_l1(_config) do
    endpoint = get_in(config, ["l1_network", "endpoint"])

    if endpoint do
      # Simulate connection establishment
      Logger.info("Connecting to L1 at #{endpoint}")
      {:ok, %{endpoint: endpoint, status: :connected}}
    else
      {:error, :missing_l1_endpoint}
    end
  end

  defp connect_to_l2(_config) do
    endpoint = get_in(config, ["l2_network", "endpoint"])

    if endpoint do
      # Simulate connection establishment
      Logger.info("Connecting to L2 at #{endpoint}")
      {:ok, %{endpoint: endpoint, status: :connected}}
    else
      {:error, :missing_l2_endpoint}
    end
  end

  defp start_rollup_handler(_state) do
    rollup_name = :"#{state.network_name}_rollup"

    rollup_pid =
      case state.network_type do
        "optimistic_rollup" ->
          {:ok, pid} = OptimisticRollup.start_link(rollup_name, state.config)
          pid

        "zk_rollup" ->
          {:ok, pid} = ZKRollup.start_link(rollup_name, state.config)
          pid
      end

    {:ok, %{state | rollup_pid: rollup_pid}}
  end

  defp start_bridge_handler(_state) do
    bridge_name = :"#{state.network_name}_bridge"
    {:ok, bridge_pid} = CrossLayerBridge.start_link(bridge_name, state.config)

    {:ok, %{state | bridge_pid: bridge_pid}}
  end

  defp cleanup_connections(_state) do
    # Cleanup rollup handler
    if state.rollup_pid do
      GenServer.stop(state.rollup_pid, :normal)
    end

    # Cleanup bridge handler
    if state.bridge_pid do
      GenServer.stop(state.bridge_pid, :normal)
    end

    %{state | l1_connection: nil, l2_connection: nil, rollup_pid: nil, bridge_pid: nil}
  end

  defp submit_to_l2(_state, transaction) do
    # Simulate transaction submission
    tx_hash =
      :crypto.hash(:sha256, :erlang.term_to_binary(transaction))
      |> Base.encode16(case: :lower)

    Logger.info("Submitted transaction to #{state.network_name}: 0x#{tx_hash}")
    {:ok, "0x#{tx_hash}"}
  end

  defp query_l2_state(_state, address, slot) do
    # Simulate state query
    state_value =
      :crypto.hash(:sha256, "#{address}#{slot}")
      |> Base.encode16(case: :lower)

    Logger.debug("Queried state on #{state.network_name}: #{address}")
    {:ok, "0x#{state_value}"}
  end

  defp initiate_l2_withdrawal(_state, _params) do
    # Simulate withdrawal initiation
    withdrawal_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    Logger.info("Initiated withdrawal on #{state.network_name}: 0x#{withdrawal_id}")
    {:ok, "0x#{withdrawal_id}"}
  end

  defp init_metrics do
    %{
      connections_established: 0,
      transactions_submitted: 0,
      state_queries: 0,
      withdrawals_initiated: 0,
      rollup_events_received: 0,
      bridge_events_received: 0,
      last_activity: DateTime.utc_now()
    }
  end

  defp update_metrics(_state, metric_type) do
    updated_metrics =
      state.metrics
      |> Map.update(metric_type, 1, &(&1 + 1))
      |> Map.put(:last_activity, DateTime.utc_now())

    %{state | metrics: updated_metrics}
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, &deep_resolve/3)
  end

  defp deep_merge(_left, right), do: right

  defp deep_resolve(_key, left, right) when is_map(left) and is_map(right) do
    deep_merge(left, right)
  end

  defp deep_resolve(_key, _left, right), do: right
end
