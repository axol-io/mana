defmodule ExWire.Eth2.MEVBoost do
  @moduledoc """
  MEV-Boost integration for proposer-builder separation.
  Allows validators to outsource block building to maximize MEV extraction.
  """

  use GenServer
  require Logger

  alias ExWire.Eth2.ExecutionPayload

  defstruct [
    :relay_urls,
    :public_key,
    :preferred_relays,
    :min_bid,
    :fallback_enabled,
    :metrics,
    :active_registrations,
    :config
  ]

  @type relay_info :: %{
          url: String.t(),
          public_key: binary(),
          network: atom(),
          priority: non_neg_integer()
        }

  @type builder_bid :: %{
          header: ExecutionPayload.Header.t(),
          value: non_neg_integer(),
          pubkey: binary(),
          signature: binary()
        }

  @type signed_builder_bid :: %{
          message: builder_bid(),
          signature: binary()
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Register validator with relays
  """
  def register_validator(pubkey, fee_recipient, gas_limit, timestamp) do
    GenServer.call(__MODULE__, {:register_validator, pubkey, fee_recipient, gas_limit, timestamp})
  end

  @doc """
  Get header for slot from builders
  """
  def get_header(slot, parent_hash, pubkey) do
    GenServer.call(__MODULE__, {:get_header, slot, parent_hash, pubkey}, 10_000)
  end

  @doc """
  Get payload for accepted header
  """
  def get_payload(signed_blinded_beacon_block) do
    GenServer.call(__MODULE__, {:get_payload, signed_blinded_beacon_block}, 5_000)
  end

  @doc """
  Check relay status
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Update relay configuration
  """
  def update_relays(relay_urls) do
    GenServer.call(__MODULE__, {:update_relays, relay_urls})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting MEV-Boost client")

    state = %__MODULE__{
      relay_urls: parse_relay_urls(opts[:relay_urls] || default_relays()),
      public_key: opts[:public_key],
      preferred_relays: opts[:preferred_relays] || [],
      min_bid: opts[:min_bid] || 0,
      fallback_enabled: Keyword.get(opts, :fallback_enabled, true),
      metrics: initialize_metrics(),
      active_registrations: %{},
      config: build_config(opts)
    }

    # Check relay health on startup
    state = check_relay_health(state)

    # Schedule periodic health checks
    schedule_health_check()

    {:ok, _state}
  end

  @impl true
  def handle_call(
        {:register_validator, pubkey, fee_recipient, gas_limit, timestamp},
        _from,
        _state
      ) do
    registration = %{
      message: %{
        fee_recipient: fee_recipient,
        gas_limit: gas_limit,
        timestamp: timestamp,
        pubkey: pubkey
      },
      # Would be signed by validator
      signature: <<0::768>>
    }

    # Register with all relays
    results =
      Enum.map(state.relay_urls, fn relay ->
        register_with_relay(relay, registration)
      end)

    successful = Enum.count(results, fn {status, _} -> status == :ok end)

    # Update active registrations
    state =
      put_in(state.active_registrations[pubkey], %{
        fee_recipient: fee_recipient,
        gas_limit: gas_limit,
        timestamp: timestamp,
        relay_count: successful
      })

    # Update metrics
    state = update_in(state.metrics.registrations, &(&1 + 1))

    Logger.info("Registered validator with #{successful}/#{length(state.relay_urls)} relays")

    {:reply, {:ok, successful}, state}
  end

  @impl true
  def handle_call({:get_header, slot, parent_hash, pubkey}, _from, _state) do
    Logger.debug("Requesting header for slot #{slot}")

    # Request headers from all relays in parallel
    tasks =
      Enum.map(state.relay_urls, fn relay ->
        Task.async(fn ->
          {relay, request_header(relay, slot, parent_hash, pubkey)}
        end)
      end)

    # Collect responses with timeout
    responses =
      Enum.map(tasks, fn task ->
        case Task.yield(task, 3000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {nil, {:error, :timeout}}
        end
      end)

    # Filter successful responses
    valid_bids =
      responses
      |> Enum.filter(fn {_relay, result} ->
        match?({:ok, _}, result)
      end)
      |> Enum.map(fn {relay, {:ok, bid}} ->
        {relay, bid}
      end)

    if length(valid_bids) > 0 do
      # Select best bid
      {best_relay, best_bid} = select_best_bid(valid_bids, state)

      # Update metrics
      state = update_in(state.metrics.headers_received, &(&1 + 1))
      state = update_in(state.metrics.total_value, &(&1 + best_bid.value))

      Logger.info("Selected bid from #{best_relay.url} with value #{best_bid.value}")

      {:reply, {:ok, best_bid}, state}
    else
      Logger.warning("No valid bids received for slot #{slot}")
      state = update_in(state.metrics.missed_slots, &(&1 + 1))

      if state.fallback_enabled do
        {:reply, {:fallback, build_local_header(slot, parent_hash)}, state}
      else
        {:reply, {:error, :no_bids}, state}
      end
    end
  end

  @impl true
  def handle_call({:get_payload, signed_blinded_beacon_block}, _from, _state) do
    # Extract header from blinded block
    header = signed_blinded_beacon_block.message.body.execution_payload_header

    # Find which relay provided this header
    relay = find_relay_for_header(state, header)

    if relay do
      case request_payload(relay, signed_blinded_beacon_block) do
        {:ok, payload} ->
          # Verify payload matches header
          if verify_payload_matches_header(payload, header) do
            state = update_in(state.metrics.payloads_received, &(&1 + 1))
            {:reply, {:ok, payload}, state}
          else
            Logger.error("Payload does not match header!")
            state = update_in(state.metrics.invalid_payloads, &(&1 + 1))
            {:reply, {:error, :invalid_payload}, state}
          end

        {:error, _reason} ->
          Logger.error("Failed to get payload: #{inspect(reason)}")
          state = update_in(state.metrics.payload_errors, &(&1 + 1))
          {:reply, {:error, _reason}, state}
      end
    else
      {:reply, {:error, :relay_not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, _state) do
    status = %{
      relay_count: length(state.relay_urls),
      healthy_relays: count_healthy_relays(state),
      active_registrations: map_size(state.active_registrations),
      metrics: state.metrics
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call({:update_relays, relay_urls}, _from, _state) do
    state = %{state | relay_urls: parse_relay_urls(relay_urls)}
    state = check_relay_health(state)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:health_check, _state) do
    state = check_relay_health(state)
    schedule_health_check()
    {:noreply, state}
  end

  # Private Functions - Relay Communication

  defp register_with_relay(relay, registration) do
    url = "#{relay.url}/eth/v1/builder/validators"
    headers = [{"Content-Type", "application/json"}]
    body = Jason.encode!([registration])

    case HTTPoison.post(url, body, headers) do
      {:ok, %{status_code: 200}} ->
        {:ok, :registered}

      {:ok, response} ->
        {:error, {:http_error, response.status_code}}

      {:error, _reason} ->
        {:error, _reason}
    end
  catch
    _ -> {:error, :request_failed}
  end

  defp request_header(relay, slot, parent_hash, pubkey) do
    url =
      "#{relay.url}/eth/v1/builder/header/#{slot}/#{Base.encode16(parent_hash, case: :lower)}/#{Base.encode16(pubkey, case: :lower)}"

    headers = []

    case HTTPoison.get(url, headers) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} ->
            {:ok, parse_builder_bid(data)}

          {:error, _} ->
            {:error, :invalid_response}
        end

      {:ok, response} ->
        {:error, {:http_error, response.status_code}}

      {:error, _reason} ->
        {:error, _reason}
    end
  catch
    _ -> {:error, :request_failed}
  end

  defp request_payload(relay, signed_blinded_beacon_block) do
    url = "#{relay.url}/eth/v1/builder/blinded_blocks"
    headers = [{"Content-Type", "application/json"}]
    body = Jason.encode!(signed_blinded_beacon_block)

    case HTTPoison.post(url, body, headers) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} ->
            {:ok, parse_execution_payload(data)}

          {:error, _} ->
            {:error, :invalid_response}
        end

      {:ok, response} ->
        {:error, {:http_error, response.status_code}}

      {:error, _reason} ->
        {:error, _reason}
    end
  catch
    _ -> {:error, :request_failed}
  end

  # Private Functions - Bid Selection

  defp select_best_bid(bids, _state) do
    # Filter by minimum bid
    valid_bids =
      Enum.filter(bids, fn {_relay, bid} ->
        bid.value >= state.min_bid
      end)

    # Prefer relays if configured
    preferred_bids =
      if length(state.preferred_relays) > 0 do
        Enum.filter(valid_bids, fn {relay, _bid} ->
          relay.url in state.preferred_relays
        end)
      else
        valid_bids
      end

    # Use preferred if available, otherwise all valid
    bids_to_consider =
      if length(preferred_bids) > 0 do
        preferred_bids
      else
        valid_bids
      end

    # Select highest value
    Enum.max_by(bids_to_consider, fn {_relay, bid} -> bid.value end)
  end

  defp build_local_header(slot, parent_hash) do
    # Build a local header as fallback
    %{
      header: %{
        parent_hash: parent_hash,
        fee_recipient: <<0::160>>,
        state_root: <<0::256>>,
        receipts_root: <<0::256>>,
        logs_bloom: <<0::2048>>,
        prev_randao: <<0::256>>,
        block_number: 0,
        gas_limit: 30_000_000,
        gas_used: 0,
        timestamp: compute_timestamp_at_slot(slot),
        extra_data: <<>>,
        base_fee_per_gas: 1_000_000_000,
        block_hash: <<0::256>>,
        transactions_root: <<0::256>>,
        withdrawals_root: <<0::256>>
      },
      value: 0,
      pubkey: <<0::384>>,
      signature: <<0::768>>
    }
  end

  # Private Functions - Verification

  defp verify_payload_matches_header(payload, header) do
    # Verify key fields match
    payload.parent_hash == header.parent_hash &&
      payload.fee_recipient == header.fee_recipient &&
      payload.state_root == header.state_root &&
      payload.receipts_root == header.receipts_root &&
      payload.block_number == header.block_number &&
      payload.gas_limit == header.gas_limit &&
      payload.timestamp == header.timestamp &&
      payload.base_fee_per_gas == header.base_fee_per_gas
  end

  defp find_relay_for_header(_state, _header) do
    # In production, would track which relay provided which header
    nil
  end

  # Private Functions - Health Monitoring

  defp check_relay_health(_state) do
    # Check each relay's health
    Enum.each(state.relay_urls, fn relay ->
      Task.async(fn ->
        check_relay_status(relay)
      end)
    end)

    state
  end

  defp check_relay_status(relay) do
    url = "#{relay.url}/eth/v1/builder/status"

    case HTTPoison.get(url, [], timeout: 2000) do
      {:ok, %{status_code: 200}} ->
        Logger.debug("Relay #{relay.url} is healthy")
        :healthy

      _ ->
        Logger.warning("Relay #{relay.url} is unhealthy")
        :unhealthy
    end
  catch
    _ -> :unhealthy
  end

  defp count_healthy_relays(_state) do
    # Count relays that responded recently
    # In production, would track health status
    length(state.relay_urls)
  end

  # Private Functions - Parsing

  defp parse_relay_urls(urls) when is_list(urls) do
    Enum.map(urls, fn url ->
      parse_relay_url(url)
    end)
  end

  defp parse_relay_url(url) when is_binary(url) do
    %{
      url: url,
      # Would parse from URL or config
      public_key: <<0::384>>,
      network: :mainnet,
      priority: 1
    }
  end

  defp parse_relay_url(relay) when is_map(relay) do
    relay
  end

  defp parse_builder_bid(data) do
    %{
      header: parse_execution_payload_header(data["data"]["message"]["header"]),
      value: String.to_integer(data["data"]["message"]["value"]),
      pubkey: decode_hex(data["data"]["message"]["pubkey"]),
      signature: decode_hex(data["data"]["signature"])
    }
  end

  defp parse_execution_payload_header(data) do
    %{
      parent_hash: decode_hex(data["parent_hash"]),
      fee_recipient: decode_hex(data["fee_recipient"]),
      state_root: decode_hex(data["state_root"]),
      receipts_root: decode_hex(data["receipts_root"]),
      logs_bloom: decode_hex(data["logs_bloom"]),
      prev_randao: decode_hex(data["prev_randao"]),
      block_number: String.to_integer(data["block_number"]),
      gas_limit: String.to_integer(data["gas_limit"]),
      gas_used: String.to_integer(data["gas_used"]),
      timestamp: String.to_integer(data["timestamp"]),
      extra_data: decode_hex(data["extra_data"]),
      base_fee_per_gas: String.to_integer(data["base_fee_per_gas"]),
      block_hash: decode_hex(data["block_hash"]),
      transactions_root: decode_hex(data["transactions_root"]),
      withdrawals_root: decode_hex(data["withdrawals_root"])
    }
  end

  defp parse_execution_payload(data) do
    %ExecutionPayload{
      parent_hash: decode_hex(data["data"]["parent_hash"]),
      fee_recipient: decode_hex(data["data"]["fee_recipient"]),
      state_root: decode_hex(data["data"]["state_root"]),
      receipts_root: decode_hex(data["data"]["receipts_root"]),
      logs_bloom: decode_hex(data["data"]["logs_bloom"]),
      prev_randao: decode_hex(data["data"]["prev_randao"]),
      block_number: String.to_integer(data["data"]["block_number"]),
      gas_limit: String.to_integer(data["data"]["gas_limit"]),
      gas_used: String.to_integer(data["data"]["gas_used"]),
      timestamp: String.to_integer(data["data"]["timestamp"]),
      extra_data: decode_hex(data["data"]["extra_data"]),
      base_fee_per_gas: String.to_integer(data["data"]["base_fee_per_gas"]),
      block_hash: decode_hex(data["data"]["block_hash"]),
      transactions: Enum.map(data["data"]["transactions"], &decode_hex/1),
      withdrawals: parse_withdrawals(data["data"]["withdrawals"])
    }
  end

  defp parse_withdrawals(nil), do: []

  defp parse_withdrawals(withdrawals) do
    Enum.map(withdrawals, fn w ->
      %{
        index: String.to_integer(w["index"]),
        validator_index: String.to_integer(w["validator_index"]),
        address: decode_hex(w["address"]),
        amount: String.to_integer(w["amount"])
      }
    end)
  end

  defp decode_hex("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_hex(hex), do: Base.decode16!(hex, case: :mixed)

  # Private Functions - Helpers

  defp compute_timestamp_at_slot(slot) do
    # Mainnet genesis
    genesis_time = 1_606_824_023
    genesis_time + slot * 12
  end

  defp default_relays do
    [
      "https://0xac6e77dfe25ecd6110b8e780608cce0dab71fdd5ebea22a16c0205200f2f8e2e3ad3b71d3499c54ad14d6c21b41a37ae@boost-relay.flashbots.net",
      "https://0xa1559ace749633b997cb3fdacffb890aeebdb0f5a3b6aaa7eeeaf1a38af0a8fe88b9e4b1f61f236d2e64d95733327a62@relay.ultrasound.money",
      "https://0x8b5d2e73e2a3a55c6c87b8b6eb92e0149a125c852751db1422fa951e42a09b82c142c3ea98d0d9930b056a3bc9896b8f@bloxroute.max-profit.blxrbdn.com"
    ]
  end

  defp initialize_metrics do
    %{
      registrations: 0,
      headers_received: 0,
      payloads_received: 0,
      missed_slots: 0,
      invalid_payloads: 0,
      payload_errors: 0,
      total_value: 0,
      average_bid: 0
    }
  end

  defp build_config(opts) do
    %{
      timeout: Keyword.get(opts, :timeout, 5000),
      max_retries: Keyword.get(opts, :max_retries, 2),
      circuit_breaker_threshold: Keyword.get(opts, :circuit_breaker_threshold, 5)
    }
  end

  defp schedule_health_check do
    # Every minute
    Process.send_after(self(), :health_check, 60_000)
  end
end

# Placeholder for HTTPoison - would use actual HTTP client
defmodule HTTPoison do
  def get(_url, _headers, _opts \\ []), do: {:error, :not_implemented}
  def post(_url, _body, _headers), do: {:error, :not_implemented}
end
