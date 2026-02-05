defmodule ExWire.DVT.CommunicationSupervisor do
  @moduledoc """
  Supervisor for DVT Phase 3 Communication & Networking components.

  Coordinates and manages:
  - P2P Protocol handler for secure operator communication
  - Message authentication and replay protection
  - Network partition detection and recovery
  - GossipSub optimization for validator duties
  """

  use Supervisor
  require Logger

  alias ExWire.DVT.{P2PProtocol, PartitionDetector, GossipSubOptimizer}

  @doc """
  Start the DVT Communication Supervisor.
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the status of all DVT communication components.
  """
  def get_communication_status() do
    children = Supervisor.which_children(__MODULE__)

    status =
      Enum.map(children, fn {id, pid, _type, _modules} ->
        case pid do
          pid when is_pid(pid) ->
            {id, :running, get_component_health(id, pid)}

          _ ->
            {id, :not_running, nil}
        end
      end)

    %{
      supervisor_status: :running,
      components: status,
      total_components: length(children),
      healthy_components: count_healthy_components(status)
    }
  end

  @doc """
  Restart a specific DVT communication component.
  """
  def restart_component(component_id) do
    case Supervisor.restart_child(__MODULE__, component_id) do
      {:ok, _pid} ->
        Logger.info("Restarted DVT component: #{component_id}")
        :ok

      {:ok, _pid, _info} ->
        Logger.info("Restarted DVT component: #{component_id}")
        :ok

      {:error, _reason} ->
        Logger.error("Failed to restart DVT component #{component_id}: #{inspect(reason)}")
        {:error, _reason}
    end
  end

  @doc """
  Configure DVT communication for a new cluster.
  """
  def configure_cluster(cluster_id, _config) do
    with :ok <- P2PProtocol.join_cluster(cluster_id, config.node_id, config.auth_key),
         :ok <-
           PartitionDetector.monitor_cluster(
             cluster_id,
             config.node_count,
             config.threshold,
             config.partition_tolerance
           ),
         :ok <- GossipSubOptimizer.configure_cluster_topics(cluster_id, config.topics) do
      Logger.info("DVT communication configured for cluster #{cluster_id}")
      :ok
    else
      {:error, _reason} = error ->
        Logger.error(
          "Failed to configure DVT communication for cluster #{cluster_id}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Remove DVT communication configuration for a cluster.
  """
  def unconfigure_cluster(cluster_id) do
    # Gracefully leave cluster communication
    :ok = P2PProtocol.leave_cluster(cluster_id)
    :ok = PartitionDetector.unmonitor_cluster(cluster_id)

    Logger.info("DVT communication unconfigured for cluster #{cluster_id}")
    :ok
  end

  ## Supervisor Callbacks

  @impl true
  def init(opts) do
    # Extract configuration options
    node_id = Keyword.get(opts, :node_id, generate_node_id())
    p2p_opts = Keyword.get(opts, :p2p_opts, [])
    partition_opts = Keyword.get(opts, :partition_opts, [])
    gossipsub_opts = Keyword.get(opts, :gossipsub_opts, [])

    # Define child specifications
    children = [
      # GossipSub Optimizer - Start first as other components depend on it
      {GossipSubOptimizer, [name: ExWire.DVT.GossipSubOptimizer] ++ gossipsub_opts},

      # Partition Detector - Monitor network health
      {PartitionDetector,
       [node_id: node_id, name: ExWire.DVT.PartitionDetector] ++ partition_opts},

      # P2P Protocol Handler - Main communication coordinator
      {P2PProtocol, [node_id: node_id, name: ExWire.DVT.P2PProtocol] ++ p2p_opts}
    ]

    # Use one_for_one strategy - if one component fails, restart only that component
    # This ensures that network issues don't cascade across all components
    opts = [
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 60,
      name: __MODULE__
    ]

    Logger.info("Starting DVT Communication Supervisor", node_id: node_id)

    Supervisor.init(children, opts)
  end

  ## Private Functions

  defp generate_node_id() do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp get_component_health(component_id, _pid) do
    try do
      case component_id do
        ExWire.DVT.P2PProtocol ->
          P2PProtocol.get_network_status()

        ExWire.DVT.PartitionDetector ->
          PartitionDetector.get_partition_status()

        ExWire.DVT.GossipSubOptimizer ->
          GossipSubOptimizer.get_performance_stats()

        _ ->
          %{status: :unknown}
      end
    catch
      :exit, {:noproc, _} ->
        %{status: :not_responding}

      :exit, {:timeout, _} ->
        %{status: :timeout}

      error ->
        %{status: :error, details: inspect(error)}
    end
  end

  defp count_healthy_components(status) do
    Enum.count(status, fn {_id, component_status, health} ->
      component_status == :running and health != nil and
        health[:status] not in [:error, :timeout, :not_responding]
    end)
  end
end
