defmodule ExWire.Consensus.GeographicRouter do
  @moduledoc """
  Geographic routing system for multi-datacenter Ethereum operations.

  This module provides intelligent routing of requests to the nearest or most
  appropriate replica based on:
  - Geographic distance (great circle distance)
  - Network latency measurements
  - Regional compliance requirements
  - Load balancing across regions
  - Fault tolerance during regional outages

  ## Features

  - **Latency-aware routing**: Route to replica with lowest measured latency
  - **Geographic optimization**: Calculate great circle distance for cold start
  - **Compliance-aware**: Route based on data sovereignty requirements
  - **Load balancing**: Distribute requests across healthy replicas
  - **Automatic failover**: Route around unhealthy or overloaded replicas
  - **Edge optimization**: Cache routing decisions for frequently accessed data

  ## Usage

      # Initialize router with replica locations
      {:ok, router} = GeographicRouter.start_link()
      
      # Add datacenter with coordinates
      :ok = GeographicRouter.add_datacenter("us-east-1", {39.0458, -76.6413})
      
      # Route request optimally
      {:ok, datacenter} = GeographicRouter.route_request(request, client_ip)
  """

  use GenServer
  require Logger

  alias ExWire.Consensus.DistributedConsensusCoordinator

  @type coordinates :: {latitude :: float(), longitude :: float()}
  @type datacenter_id :: String.t()
  @type client_location :: %{
          ip_address: String.t(),
          coordinates: coordinates(),
          country_code: String.t(),
          region: String.t(),
          isp: String.t()
        }

  @type datacenter_info :: %{
          datacenter_id: datacenter_id(),
          coordinates: coordinates(),
          region: String.t(),
          country_code: String.t(),
          compliance_zones: [String.t()],
          capacity_factor: float(),
          current_load: float(),
          average_latency_ms: float(),
          status: :healthy | :degraded | :unhealthy,
          priority_tier: integer()
        }

  @type routing_decision :: %{
          selected_datacenter: datacenter_id(),
          selection_reason: atom(),
          alternatives: [datacenter_id()],
          decision_time_ms: float(),
          expected_latency_ms: float()
        }

  defstruct [
    :datacenters,
    :client_cache,
    :latency_measurements,
    :routing_policies,
    :geolocation_service,
    :compliance_rules,
    :load_balancer_state,
    :failover_state
  ]

  @type t :: %__MODULE__{
          datacenters: %{datacenter_id() => datacenter_info()},
          client_cache: %{String.t() => client_location()},
          latency_measurements: %{String.t() => %{datacenter_id() => [non_neg_integer()]}},
          routing_policies: %{atom() => term()},
          geolocation_service: module(),
          compliance_rules: %{String.t() => [datacenter_id()]},
          load_balancer_state: map(),
          failover_state: map()
        }

  # Default configuration
  @earth_radius_km 6371
  @latency_history_limit 100
  @client_cache_ttl_minutes 60
  @geolocation_cache_ttl_hours 24
  @routing_decision_cache_ttl_seconds 300

  @name __MODULE__

  # Public API

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Add a datacenter with its geographic coordinates and configuration.
  """
  @spec add_datacenter(datacenter_id(), coordinates(), Keyword.t()) :: :ok
  def add_datacenter(datacenter_id, coordinates, opts \\ []) do
    GenServer.call(@name, {:add_datacenter, datacenter_id, coordinates, opts})
  end

  @doc """
  Remove a datacenter from routing decisions.
  """
  @spec remove_datacenter(datacenter_id()) :: :ok
  def remove_datacenter(datacenter_id) do
    GenServer.call(@name, {:remove_datacenter, datacenter_id})
  end

  @doc """
  Route a request to the optimal datacenter based on client location and policies.
  """
  @spec route_request(term(), String.t(), Keyword.t()) ::
          {:ok, datacenter_id()} | {:error, term()}
  def route_request(request, client_ip, opts \\ []) do
    GenServer.call(@name, {:route_request, request, client_ip, opts})
  end

  @doc """
  Get detailed routing decision with reasoning and alternatives.
  """
  @spec get_routing_decision(term(), String.t(), Keyword.t()) ::
          {:ok, routing_decision()} | {:error, term()}
  def get_routing_decision(request, client_ip, opts \\ []) do
    GenServer.call(@name, {:get_routing_decision, request, client_ip, opts})
  end

  @doc """
  Update datacenter status and load information.
  """
  @spec update_datacenter_status(datacenter_id(), Keyword.t()) :: :ok
  def update_datacenter_status(datacenter_id, updates) do
    GenServer.cast(@name, {:update_datacenter_status, datacenter_id, updates})
  end

  @doc """
  Record latency measurement for adaptive routing.
  """
  @spec record_latency(datacenter_id(), String.t(), non_neg_integer()) :: :ok
  def record_latency(datacenter_id, client_ip, latency_ms) do
    GenServer.cast(@name, {:record_latency, datacenter_id, client_ip, latency_ms})
  end

  @doc """
  Set compliance rules for data sovereignty requirements.
  """
  @spec set_compliance_rules(%{String.t() => [datacenter_id()]}) :: :ok
  def set_compliance_rules(rules) do
    GenServer.cast(@name, {:set_compliance_rules, rules})
  end

  @doc """
  Get current datacenter information and routing statistics.
  """
  @spec get_datacenter_info() :: %{datacenter_id() => datacenter_info()}
  def get_datacenter_info() do
    GenServer.call(@name, :get_datacenter_info)
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    geolocation_service = Keyword.get(opts, :geolocation_service, __MODULE__.IPLocationService)

    # Schedule periodic maintenance
    schedule_cache_cleanup()
    schedule_latency_analysis()

    state = %__MODULE__{
      datacenters: %{},
      client_cache: %{},
      latency_measurements: %{},
      routing_policies: default_routing_policies(),
      geolocation_service: geolocation_service,
      compliance_rules: %{},
      load_balancer_state: %{},
      failover_state: %{}
    }

    Logger.info("[GeographicRouter] Started with geolocation service: #{geolocation_service}")

    {:ok, _state}
  end

  @impl GenServer
  def handle_call({:add_datacenter, datacenter_id, coordinates, opts}, _from, _state) do
    datacenter_info = %{
      datacenter_id: datacenter_id,
      coordinates: coordinates,
      region: Keyword.get(opts, :region, "unknown"),
      country_code: Keyword.get(opts, :country_code, "US"),
      compliance_zones: Keyword.get(opts, :compliance_zones, []),
      capacity_factor: Keyword.get(opts, :capacity_factor, 1.0),
      current_load: 0.0,
      average_latency_ms: 0.0,
      status: :healthy,
      priority_tier: Keyword.get(opts, :priority_tier, 1)
    }

    new_datacenters = Map.put(state.datacenters, datacenter_id, datacenter_info)
    new_state = %{state | datacenters: new_datacenters}

    Logger.info("[GeographicRouter] Added datacenter #{datacenter_id} at #{inspect(coordinates)}")

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:remove_datacenter, datacenter_id}, _from, _state) do
    new_datacenters = Map.delete(state.datacenters, datacenter_id)
    new_state = %{state | datacenters: new_datacenters}

    Logger.info("[GeographicRouter] Removed datacenter #{datacenter_id}")

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:route_request, request, client_ip, opts}, _from, _state) do
    case determine_optimal_datacenter(request, client_ip, opts, state) do
      {:ok, datacenter_id} ->
        Logger.debug(
          "[GeographicRouter] Routed request to #{datacenter_id} for client #{client_ip}"
        )

        {:reply, {:ok, datacenter_id}, state}

      {:error, _reason} ->
        Logger.error(
          "[GeographicRouter] Routing failed for client #{client_ip}: #{inspect(reason)}"
        )

        {:reply, {:error, _reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:get_routing_decision, request, client_ip, opts}, _from, _state) do
    start_time = System.monotonic_time(:millisecond)

    case determine_optimal_datacenter_with_reasoning(request, client_ip, opts, state) do
      {:ok, decision} ->
        end_time = System.monotonic_time(:millisecond)
        decision_with_time = %{decision | decision_time_ms: end_time - start_time}
        {:reply, {:ok, decision_with_time}, state}

      {:error, _reason} ->
        {:reply, {:error, _reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:get_datacenter_info, _from, _state) do
    {:reply, state.datacenters, state}
  end

  @impl GenServer
  def handle_cast({:update_datacenter_status, datacenter_id, updates}, _state) do
    case Map.get(state.datacenters, datacenter_id) do
      nil ->
        Logger.warning(
          "[GeographicRouter] Attempted to update unknown datacenter: #{datacenter_id}"
        )

        {:noreply, state}

      datacenter_info ->
        updated_info =
          datacenter_info
          |> maybe_update(:status, Keyword.get(updates, :status))
          |> maybe_update(:current_load, Keyword.get(updates, :current_load))
          |> maybe_update(:average_latency_ms, Keyword.get(updates, :average_latency_ms))

        new_datacenters = Map.put(state.datacenters, datacenter_id, updated_info)
        new_state = %{state | datacenters: new_datacenters}

        Logger.debug(
          "[GeographicRouter] Updated datacenter #{datacenter_id}: #{inspect(updates)}"
        )

        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_cast({:record_latency, datacenter_id, client_ip, latency_ms}, _state) do
    # Store latency measurement for adaptive routing
    client_measurements = Map.get(state.latency_measurements, client_ip, %{})
    datacenter_measurements = Map.get(client_measurements, datacenter_id, [])

    # Keep only recent measurements
    updated_measurements =
      [latency_ms | datacenter_measurements]
      |> Enum.take(@latency_history_limit)

    new_datacenter_measurements =
      Map.put(client_measurements, datacenter_id, updated_measurements)

    new_latency_measurements =
      Map.put(state.latency_measurements, client_ip, new_datacenter_measurements)

    new_state = %{state | latency_measurements: new_latency_measurements}

    Logger.debug(
      "[GeographicRouter] Recorded latency #{latency_ms}ms for #{datacenter_id} from #{client_ip}"
    )

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast({:set_compliance_rules, rules}, _state) do
    Logger.info("[GeographicRouter] Updated compliance rules: #{inspect(Map.keys(rules))}")
    {:noreply, %{state | compliance_rules: rules}}
  end

  @impl GenServer
  def handle_info(:cache_cleanup, _state) do
    # Clean up expired cache entries
    current_time = System.system_time(:second)

    # Clean client location cache
    new_client_cache =
      state.client_cache
      |> Enum.filter(fn {_ip, location} ->
        age_minutes = (current_time - location.cached_at) / 60
        age_minutes < @client_cache_ttl_minutes
      end)
      |> Map.new()

    new_state = %{state | client_cache: new_client_cache}

    schedule_cache_cleanup()
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:latency_analysis, _state) do
    # Analyze latency patterns and update datacenter average latencies
    updated_datacenters =
      state.datacenters
      |> Enum.map(fn {datacenter_id, datacenter_info} ->
        avg_latency =
          calculate_average_latency_for_datacenter(datacenter_id, state.latency_measurements)

        updated_info = %{datacenter_info | average_latency_ms: avg_latency}
        {datacenter_id, updated_info}
      end)
      |> Map.new()

    new_state = %{state | datacenters: updated_datacenters}

    schedule_latency_analysis()
    {:noreply, new_state}
  end

  # Private functions

  defp determine_optimal_datacenter(request, client_ip, opts, _state) do
    case determine_optimal_datacenter_with_reasoning(request, client_ip, opts, state) do
      {:ok, decision} -> {:ok, decision.selected_datacenter}
      {:error, _reason} -> {:error, _reason}
    end
  end

  defp determine_optimal_datacenter_with_reasoning(request, client_ip, opts, _state) do
    strategy = Keyword.get(opts, :strategy, :latency_optimized)
    compliance_required = Keyword.get(opts, :compliance_zone)

    with {:ok, client_location} <- get_client_location(client_ip, state),
         {:ok, candidates} <- get_candidate_datacenters(compliance_required, state),
         {:ok, scored_candidates} <-
           score_candidates(candidates, client_location, strategy, state) do
      case select_best_candidate(scored_candidates) do
        {:ok, best_datacenter, alternatives} ->
          decision = %{
            selected_datacenter: best_datacenter.datacenter_id,
            selection_reason: best_datacenter.selection_reason,
            alternatives: Enum.map(alternatives, & &1.datacenter_id),
            # Will be filled by caller
            decision_time_ms: 0.0,
            expected_latency_ms: best_datacenter.expected_latency_ms
          }

          {:ok, decision}

        {:error, _reason} ->
          {:error, _reason}
      end
    end
  end

  defp get_client_location(client_ip, _state) do
    case Map.get(state.client_cache, client_ip) do
      nil ->
        # Perform geolocation lookup
        case _state.geolocation_service.lookup(client_ip) do
          {:ok, location} ->
            cached_location = Map.put(location, :cached_at, System.system_time(:second))
            {:ok, cached_location}

          {:error, _reason} ->
            # Fallback to default location
            Logger.warning(
              "[GeographicRouter] Geolocation failed for #{client_ip}: #{inspect(reason)}"
            )

            {:ok, default_client_location()}
        end

      cached_location ->
        {:ok, cached_location}
    end
  end

  defp get_candidate_datacenters(nil, _state) do
    # No compliance requirements - all healthy datacenters are candidates
    candidates =
      state.datacenters
      |> Enum.filter(fn {_id, info} -> info.status == :healthy end)
      |> Enum.map(fn {_id, info} -> info end)

    {:ok, candidates}
  end

  defp get_candidate_datacenters(compliance_zone, _state) do
    # Filter datacenters by compliance requirements
    allowed_datacenters = Map.get(state.compliance_rules, compliance_zone, [])

    candidates =
      state.datacenters
      |> Enum.filter(fn {datacenter_id, info} ->
        info.status == :healthy and datacenter_id in allowed_datacenters
      end)
      |> Enum.map(fn {_id, info} -> info end)

    case candidates do
      [] -> {:error, :no_compliant_datacenters}
      _ -> {:ok, candidates}
    end
  end

  defp score_candidates(candidates, client_location, strategy, _state) do
    scored_candidates =
      candidates
      |> Enum.map(fn datacenter ->
        score = calculate_datacenter_score(datacenter, client_location, strategy, state)
        expected_latency = estimate_latency(datacenter, client_location, state)
        selection_reason = get_selection_reason(strategy, score)

        %{
          datacenter_id: datacenter.datacenter_id,
          datacenter_info: datacenter,
          score: score,
          expected_latency_ms: expected_latency,
          selection_reason: selection_reason
        }
      end)
      # Higher score is better
      |> Enum.sort_by(& &1.score, :desc)

    {:ok, scored_candidates}
  end

  defp select_best_candidate([]) do
    {:error, :no_candidates}
  end

  defp select_best_candidate([best | alternatives]) do
    {:ok, best, alternatives}
  end

  defp calculate_datacenter_score(datacenter, client_location, strategy, _state) do
    base_score = 100.0

    # Factor in geographic distance
    distance_km =
      calculate_great_circle_distance(
        client_location.coordinates,
        datacenter.coordinates
      )

    # Penalize distant datacenters
    distance_score = max(0, 100 - distance_km / 100)

    # Factor in measured latency if available
    latency_score =
      case get_measured_latency(datacenter.datacenter_id, client_location.ip_address, state) do
        nil -> datacenter.average_latency_ms |> latency_to_score()
        latency_ms -> latency_ms |> latency_to_score()
      end

    # Factor in current load
    load_score = (1.0 - datacenter.current_load) * 100

    # Factor in capacity
    capacity_score = datacenter.capacity_factor * 100

    # Factor in priority tier
    priority_score = (10 - datacenter.priority_tier) * 10

    # Weighted combination based on strategy
    case strategy do
      :latency_optimized ->
        distance_score * 0.3 + latency_score * 0.5 + load_score * 0.2

      :load_balanced ->
        distance_score * 0.2 + latency_score * 0.3 + load_score * 0.4 + capacity_score * 0.1

      :geographic_nearest ->
        distance_score * 0.8 + load_score * 0.2

      :capacity_optimized ->
        distance_score * 0.2 + capacity_score * 0.5 + load_score * 0.3

      _ ->
        distance_score * 0.25 + latency_score * 0.25 + load_score * 0.25 + priority_score * 0.25
    end
  end

  defp calculate_great_circle_distance({lat1, lon1}, {lat2, lon2}) do
    # Convert to radians
    lat1_rad = lat1 * :math.pi() / 180
    lon1_rad = lon1 * :math.pi() / 180
    lat2_rad = lat2 * :math.pi() / 180
    lon2_rad = lon2 * :math.pi() / 180

    # Haversine formula
    dlat = lat2_rad - lat1_rad
    dlon = lon2_rad - lon1_rad

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1_rad) * :math.cos(lat2_rad) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    @earth_radius_km * c
  end

  defp get_measured_latency(datacenter_id, client_ip, _state) do
    case get_in(state.latency_measurements, [client_ip, datacenter_id]) do
      nil -> nil
      [] -> nil
      # Average
      measurements -> Enum.sum(measurements) / length(measurements)
    end
  end

  defp estimate_latency(datacenter, client_location, _state) do
    # Use measured latency if available, otherwise estimate from distance
    case get_measured_latency(datacenter.datacenter_id, client_location.ip_address, _state) do
      nil ->
        distance_km =
          calculate_great_circle_distance(
            client_location.coordinates,
            datacenter.coordinates
          )

        # Rough estimate: ~20ms per 1000km + base latency
        trunc(distance_km / 50 + 10)

      measured_latency ->
        measured_latency
    end
  end

  defp latency_to_score(latency_ms) do
    # Convert latency to score (lower is better)
    max(0, 100 - latency_ms / 5)
  end

  defp get_selection_reason(strategy, _score) do
    case strategy do
      :latency_optimized -> :lowest_latency
      :load_balanced -> :optimal_load
      :geographic_nearest -> :nearest_distance
      :capacity_optimized -> :highest_capacity
      _ -> :best_overall
    end
  end

  defp calculate_average_latency_for_datacenter(datacenter_id, latency_measurements) do
    all_measurements =
      latency_measurements
      |> Enum.flat_map(fn {_client_ip, client_measurements} ->
        Map.get(client_measurements, datacenter_id, [])
      end)

    case all_measurements do
      [] -> 0.0
      measurements -> Enum.sum(measurements) / length(measurements)
    end
  end

  defp maybe_update(struct, _field, nil), do: struct
  defp maybe_update(struct, field, value), do: Map.put(struct, field, value)

  defp default_client_location() do
    %{
      ip_address: "0.0.0.0",
      coordinates: {0.0, 0.0},
      country_code: "US",
      region: "unknown",
      isp: "unknown",
      cached_at: System.system_time(:second)
    }
  end

  defp default_routing_policies() do
    %{
      default_strategy: :latency_optimized,
      failover_strategy: :load_balanced,
      compliance_enforcement: :strict,
      load_balancing_threshold: 0.8
    }
  end

  defp schedule_cache_cleanup() do
    Process.send_after(self(), :cache_cleanup, @client_cache_ttl_minutes * 60 * 1000)
  end

  defp schedule_latency_analysis() do
    # Every minute
    Process.send_after(self(), :latency_analysis, 60_000)
  end
end

defmodule ExWire.Consensus.GeographicRouter.IPLocationService do
  @moduledoc """
  Default IP geolocation service implementation.

  In production, this would integrate with services like:
  - MaxMind GeoIP2
  - IPinfo.io
  - Google Geolocation API
  """

  @behaviour ExWire.Consensus.GeographicRouter.LocationService

  def lookup(ip_address) do
    # Placeholder implementation - in production would use real geolocation
    case ip_address do
      "127.0.0.1" ->
        {:ok,
         %{
           ip_address: ip_address,
           # San Francisco
           coordinates: {37.7749, -122.4194},
           country_code: "US",
           region: "California",
           isp: "localhost"
         }}

      _ ->
        # Default to NYC coordinates for unknown IPs
        {:ok,
         %{
           ip_address: ip_address,
           # New York
           coordinates: {40.7128, -74.0060},
           country_code: "US",
           region: "New York",
           isp: "unknown"
         }}
    end
  end
end

defmodule ExWire.Consensus.GeographicRouter.LocationService do
  @moduledoc """
  Behaviour for IP geolocation services.
  """

  @callback lookup(String.t()) :: {:ok, map()} | {:error, term()}
end
