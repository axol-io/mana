defmodule ExWire.LoadTest.NetworkSimulator do
  @moduledoc """
  Simulates various network conditions for load testing.

  Supports:
  - Latency injection (fixed and variable)
  - Packet loss simulation
  - Bandwidth limiting
  - Network partitions
  - Jitter and congestion
  - Geographic distribution simulation
  """

  use GenServer
  require Logger

  @default_conditions %{
    latency_ms: 0,
    packet_loss_rate: 0.0,
    bandwidth_mbps: :unlimited,
    jitter_ms: 0,
    partition_active: false,
    partition_nodes: [],
    congestion_factor: 1.0
  }

  # Geographic latency profiles (ms)
  @geographic_profiles %{
    local: {0, 5},
    regional: {10, 50},
    continental: {50, 150},
    intercontinental: {100, 300},
    satellite: {500, 800}
  }

  # Network condition presets
  @condition_presets %{
    perfect: %{latency_ms: 0, packet_loss_rate: 0.0, jitter_ms: 0},
    lan: %{latency_ms: 1, packet_loss_rate: 0.0, jitter_ms: 0},
    wifi: %{latency_ms: 5, packet_loss_rate: 0.001, jitter_ms: 2},
    dsl: %{latency_ms: 20, packet_loss_rate: 0.001, jitter_ms: 5},
    cable: %{latency_ms: 15, packet_loss_rate: 0.0005, jitter_ms: 3},
    mobile_4g: %{latency_ms: 50, packet_loss_rate: 0.01, jitter_ms: 20},
    mobile_3g: %{latency_ms: 150, packet_loss_rate: 0.02, jitter_ms: 50},
    congested: %{latency_ms: 100, packet_loss_rate: 0.05, jitter_ms: 50},
    unreliable: %{latency_ms: 200, packet_loss_rate: 0.1, jitter_ms: 100}
  }

  # Client API

  @doc """
  Start the network simulator.
  """
  def start(conditions \\ :normal) do
    GenServer.start_link(__MODULE__, conditions, name: __MODULE__)
  end

  @doc """
  Stop the network simulator.
  """
  def stop(pid \\ __MODULE__) do
    GenServer.stop(pid)
  end

  @doc """
  Add latency to all network operations.
  """
  def add_latency(amount, unit \\ :ms) do
    latency_ms = convert_to_ms(amount, unit)
    GenServer.call(__MODULE__, {:add_latency, latency_ms})
  end

  @doc """
  Set packet loss rate (0.0 to 1.0).
  """
  def set_packet_loss(rate) when rate >= 0 and rate <= 1 do
    GenServer.call(__MODULE__, {:set_packet_loss, rate})
  end

  @doc """
  Limit bandwidth.
  """
  def limit_bandwidth(amount, unit \\ :mbps) do
    bandwidth_mbps = convert_to_mbps(amount, unit)
    GenServer.call(__MODULE__, {:limit_bandwidth, bandwidth_mbps})
  end

  @doc """
  Simulate network partition.
  """
  def partition_network(duration, unit \\ :seconds) do
    duration_ms = convert_to_ms(duration * 1000, unit)
    GenServer.call(__MODULE__, {:partition_network, duration_ms})
  end

  @doc """
  Reset to normal conditions.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc """
  Apply preset network conditions.
  """
  def apply_preset(preset) when is_atom(preset) do
    GenServer.call(__MODULE__, {:apply_preset, preset})
  end

  @doc """
  Simulate geographic distribution.
  """
  def simulate_geographic_distribution(profile) when is_atom(profile) do
    GenServer.call(__MODULE__, {:geographic_distribution, profile})
  end

  @doc """
  Get current network conditions.
  """
  def get_conditions do
    GenServer.call(__MODULE__, :get_conditions)
  end

  @doc """
  Simulate a network operation with current conditions applied.
  """
  def simulate_network_operation(operation_fn) do
    conditions = get_conditions()

    # Check for partition
    if conditions.partition_active do
      {:error, :network_partition}
    else
      # Apply packet loss
      if :rand.uniform() < conditions.packet_loss_rate do
        {:error, :packet_lost}
      else
        # Apply latency and jitter
        total_latency = calculate_total_latency(conditions)

        if total_latency > 0 do
          Process.sleep(total_latency)
        end

        # Apply bandwidth limiting
        if conditions.bandwidth_mbps != :unlimited do
          apply_bandwidth_limit(conditions.bandwidth_mbps)
        end

        # Execute the operation
        try do
          {:ok, operation_fn.()}
        rescue
          error -> {:error, error}
        end
      end
    end
  end

  @doc """
  Simulate sending a message with network conditions.
  """
  def send_with_conditions(pid, message) do
    simulate_network_operation(fn ->
      send(pid, message)
    end)
  end

  @doc """
  Simulate RPC call with network conditions.
  """
  def rpc_with_conditions(node, module, function, args) do
    simulate_network_operation(fn ->
      :rpc.call(node, module, function, args)
    end)
  end

  # Server Callbacks

  def init(conditions) do
    initial_conditions =
      case conditions do
        preset when is_atom(preset) ->
          Map.merge(@default_conditions, Map.get(@condition_presets, preset, %{}))

        custom when is_map(custom) ->
          Map.merge(@default_conditions, custom)

        _ ->
          @default_conditions
      end

    Logger.info("Network simulator started with conditions: #{inspect(initial_conditions)}")
    {:ok, initial_conditions}
  end

  def handle_call({:add_latency, latency_ms}, _from, _state) do
    new_state = %{state | latency_ms: state.latency_ms + latency_ms}
    Logger.info("Added #{latency_ms}ms latency. Total: #{new_state.latency_ms}ms")
    {:reply, :ok, new_state}
  end

  def handle_call({:set_packet_loss, rate}, _from, _state) do
    new_state = %{state | packet_loss_rate: rate}
    Logger.info("Set packet loss rate to #{rate * 100}%")
    {:reply, :ok, new_state}
  end

  def handle_call({:limit_bandwidth, bandwidth_mbps}, _from, _state) do
    new_state = %{state | bandwidth_mbps: bandwidth_mbps}
    Logger.info("Limited bandwidth to #{bandwidth_mbps} Mbps")
    {:reply, :ok, new_state}
  end

  def handle_call({:partition_network, duration_ms}, _from, _state) do
    new_state = %{state | partition_active: true}
    Logger.info("Network partition activated for #{duration_ms}ms")

    # Schedule partition end
    Process.send_after(self(), :end_partition, duration_ms)

    {:reply, :ok, new_state}
  end

  def handle_call(:reset, _from, _state) do
    Logger.info("Network conditions reset to normal")
    {:reply, :ok, @default_conditions}
  end

  def handle_call({:apply_preset, preset}, _from, _state) do
    new_conditions = Map.get(@condition_presets, preset, @condition_presets[:normal])
    new_state = Map.merge(@default_conditions, new_conditions)
    Logger.info("Applied preset: #{preset}")
    {:reply, :ok, new_state}
  end

  def handle_call({:geographic_distribution, profile}, _from, _state) do
    {min_latency, max_latency} = Map.get(@geographic_profiles, profile, {0, 10})

    new_state = %{
      state
      | latency_ms: div(min_latency + max_latency, 2),
        jitter_ms: div(max_latency - min_latency, 4)
    }

    Logger.info("Applied geographic profile: #{profile}")
    {:reply, :ok, new_state}
  end

  def handle_call(:get_conditions, _from, _state) do
    {:reply, state, state}
  end

  def handle_info(:end_partition, _state) do
    Logger.info("Network partition ended")
    {:noreply, %{state | partition_active: false}}
  end

  # Private helper functions

  defp convert_to_ms(amount, :ms), do: amount
  defp convert_to_ms(amount, :seconds), do: amount * 1000
  defp convert_to_ms(amount, :minutes), do: amount * 60 * 1000

  defp convert_to_mbps(amount, :mbps), do: amount
  defp convert_to_mbps(amount, :kbps), do: amount / 1000
  defp convert_to_mbps(amount, :gbps), do: amount * 1000

  defp calculate_total_latency(conditions) do
    base_latency = conditions.latency_ms

    jitter =
      if conditions.jitter_ms > 0 do
        :rand.uniform(conditions.jitter_ms * 2) - conditions.jitter_ms
      else
        0
      end

    congestion_delay = round(base_latency * (conditions.congestion_factor - 1))

    max(0, base_latency + jitter + congestion_delay)
  end

  defp apply_bandwidth_limit(bandwidth_mbps) do
    # Simulate bandwidth limiting by adding delay based on data size
    # This is a simplified simulation
    # Assume random data size
    data_size_kb = :rand.uniform(100)
    transfer_time_ms = round(data_size_kb * 8 / (bandwidth_mbps * 1000) * 1000)

    if transfer_time_ms > 0 do
      Process.sleep(transfer_time_ms)
    end
  end
end

defmodule ExWire.LoadTest.NetworkSimulator.Middleware do
  @moduledoc """
  Middleware for intercepting network operations and applying simulated conditions.
  """

  alias ExWire.LoadTest.NetworkSimulator

  @doc """
  Wrap a GenServer call with network simulation.
  """
  def call_with_simulation(server, request, timeout \\ 5000) do
    NetworkSimulator.simulate_network_operation(fn ->
      GenServer.call(server, request, timeout)
    end)
  end

  @doc """
  Wrap a GenServer cast with network simulation.
  """
  def cast_with_simulation(server, request) do
    NetworkSimulator.simulate_network_operation(fn ->
      GenServer.cast(server, request)
    end)
  end

  @doc """
  Simulate P2P message sending.
  """
  def send_p2p_with_simulation(_peer_id, _message) do
    NetworkSimulator.simulate_network_operation(fn ->
      # Actual P2P send implementation would go here
      {:ok, :sent}
    end)
  end

  @doc """
  Simulate RPC request with network conditions.
  """
  def rpc_request_with_simulation(endpoint, method, _params) do
    NetworkSimulator.simulate_network_operation(fn ->
      # Actual RPC implementation would go here
      {:ok, %{jsonrpc: "2.0", result: :mock_result}}
    end)
  end
end

defmodule ExWire.LoadTest.NetworkSimulator.Chaos do
  @moduledoc """
  Chaos engineering features for network testing.
  """

  alias ExWire.LoadTest.NetworkSimulator

  @doc """
  Randomly inject network failures.
  """
  def random_failure(probability \\ 0.1) do
    if :rand.uniform() < probability do
      failure_type =
        Enum.random([
          :high_latency,
          :packet_loss,
          :partition,
          :bandwidth_limit
        ])

      apply_failure(failure_type)
    end
  end

  @doc """
  Apply cascading failures.
  """
  def cascading_failure do
    Logger.info("Initiating cascading network failure")

    # Start with minor issues
    NetworkSimulator.add_latency(50, :ms)
    Process.sleep(5000)

    # Escalate to packet loss
    NetworkSimulator.set_packet_loss(0.05)
    Process.sleep(5000)

    # Add bandwidth constraints
    NetworkSimulator.limit_bandwidth(10, :mbps)
    Process.sleep(5000)

    # Finally, partition
    NetworkSimulator.partition_network(10, :seconds)
  end

  @doc """
  Simulate network storm (sudden spike in issues).
  """
  def network_storm(duration_seconds \\ 30) do
    Logger.info("Network storm starting for #{duration_seconds} seconds")

    # Apply severe conditions
    NetworkSimulator.apply_preset(:congested)
    NetworkSimulator.set_packet_loss(0.15)
    NetworkSimulator.add_latency(500, :ms)

    # Schedule recovery
    Process.sleep(duration_seconds * 1000)
    NetworkSimulator.reset()

    Logger.info("Network storm ended")
  end

  defp apply_failure(:high_latency) do
    NetworkSimulator.add_latency(:rand.uniform(500) + 100, :ms)
  end

  defp apply_failure(:packet_loss) do
    NetworkSimulator.set_packet_loss(:rand.uniform() * 0.2)
  end

  defp apply_failure(:partition) do
    NetworkSimulator.partition_network(:rand.uniform(30), :seconds)
  end

  defp apply_failure(:bandwidth_limit) do
    NetworkSimulator.limit_bandwidth(:rand.uniform(10) + 1, :mbps)
  end
end
