defmodule Mix.Tasks.DvtLoadTest.MessageGenerator do
  @moduledoc """
  Message generator for DVT load testing.
  
  Generates realistic validator duty messages at configurable rates
  to simulate real-world DVT cluster operations.
  """

  use GenServer
  require Logger

  alias ExWire.DVT.{P2PProtocol, DutyConsensus}

  defstruct [
    :cluster_id,
    :message_rate,
    :test_state,
    :timer_ref,
    :slot_number,
    :epoch_number,
    :validator_duties,
    :message_count
  ]

  ## Public API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  ## GenServer Callbacks

  @impl true
  def init(config) do
    state = %__MODULE__{
      cluster_id: config.cluster_id,
      message_rate: config.message_rate,
      test_state: config.test_state,
      slot_number: 1,
      epoch_number: 0,
      validator_duties: generate_validator_duties(config.test_state),
      message_count: 0
    }

    # Start message generation timer
    interval = max(1, div(1000, config.message_rate))
    {:ok, timer_ref} = :timer.send_interval(interval, :generate_message)

    Logger.info("Message generator started: #{config.message_rate} msg/s")

    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:generate_message, state) do
    # Generate and send message
    message_type = select_message_type()
    
    case generate_message(message_type, state) do
      {:ok, message} ->
        send_message(message, state)
        
        new_state = %{state | 
          message_count: state.message_count + 1,
          slot_number: advance_slot(state.slot_number, state.epoch_number)
        }
        
        {:noreply, new_state}
        
      {:error, reason} ->
        Logger.warning("Failed to generate message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref do
      :timer.cancel(state.timer_ref)
    end
    
    Logger.info("Message generator stopped: #{state.message_count} messages sent")
    :ok
  end

  ## Private Functions

  defp generate_validator_duties(test_state) do
    # Generate realistic validator duty assignments
    test_state.participants
    |> Enum.with_index(1)
    |> Enum.map(fn {participant, validator_index} ->
      %{
        validator_index: validator_index,
        node_id: participant.node_id,
        duties: [:attestation, :sync_committee] ++ maybe_add_proposer_duty(validator_index)
      }
    end)
  end

  defp maybe_add_proposer_duty(validator_index) do
    # Randomly assign block proposal duties (roughly 1 in 8 chance per epoch)
    if rem(:os.system_time(:millisecond), 8) == rem(validator_index, 8) do
      [:block_proposal]
    else
      []
    end
  end

  defp select_message_type() do
    # Weight message types based on realistic validator operations
    random = :rand.uniform(100)
    
    cond do
      random <= 60 -> :attestation        # 60% - Most common duty
      random <= 75 -> :sync_committee     # 15% - Sync committee duties  
      random <= 85 -> :block_proposal     # 10% - Block proposals
      random <= 92 -> :aggregation        # 7%  - Attestation aggregation
      random <= 97 -> :heartbeat          # 5%  - Network heartbeats
      true         -> :performance_metrics # 3%  - Performance data
    end
  end

  defp generate_message(:attestation, state) do
    validator = Enum.random(state.validator_duties)
    
    message = %{
      duty_type: :attestation,
      slot: state.slot_number,
      validator_index: validator.validator_index,
      committee_index: :rand.uniform(32) - 1,
      attestation_data: %{
        slot: state.slot_number,
        index: :rand.uniform(32) - 1,
        beacon_block_root: generate_random_hash(),
        source: %{epoch: max(0, state.epoch_number - 1), root: generate_random_hash()},
        target: %{epoch: state.epoch_number, root: generate_random_hash()}
      },
      signature: generate_bls_signature()
    }
    
    {:ok, {:duty_consensus, message}}
  end

  defp generate_message(:sync_committee, state) do
    validator = Enum.random(state.validator_duties)
    
    message = %{
      duty_type: :sync_committee,
      slot: state.slot_number,
      validator_index: validator.validator_index,
      beacon_block_root: generate_random_hash(),
      signature: generate_bls_signature()
    }
    
    {:ok, {:duty_consensus, message}}
  end

  defp generate_message(:block_proposal, state) do
    # Find validator with proposer duty
    proposer = Enum.find(state.validator_duties, fn v -> 
      :block_proposal in v.duties 
    end) || Enum.random(state.validator_duties)
    
    message = %{
      duty_type: :block_proposal,
      slot: state.slot_number,
      validator_index: proposer.validator_index,
      block_data: %{
        slot: state.slot_number,
        proposer_index: proposer.validator_index,
        parent_root: generate_random_hash(),
        state_root: generate_random_hash(),
        body_root: generate_random_hash()
      },
      signature: generate_bls_signature()
    }
    
    {:ok, {:duty_consensus, message}}
  end

  defp generate_message(:aggregation, state) do
    validator = Enum.random(state.validator_duties)
    
    message = %{
      duty_type: :aggregation,
      slot: state.slot_number,
      validator_index: validator.validator_index,
      committee_index: :rand.uniform(32) - 1,
      aggregation_bits: generate_random_bitfield(128),
      signature: generate_bls_signature()
    }
    
    {:ok, {:duty_consensus, message}}
  end

  defp generate_message(:heartbeat, state) do
    node = Enum.random(state.test_state.participants)
    
    message = %{
      node_id: node.node_id,
      timestamp: DateTime.utc_now(),
      metrics: %{
        cpu_usage: :rand.uniform(100),
        memory_usage: :rand.uniform(100),
        network_latency: :rand.uniform(100),
        consensus_rounds: state.slot_number
      },
      status: :active
    }
    
    {:ok, {:heartbeat, message}}
  end

  defp generate_message(:performance_metrics, state) do
    message = %{
      cluster_id: state.cluster_id,
      timestamp: DateTime.utc_now(),
      metrics: %{
        messages_processed: state.message_count,
        average_latency: :rand.uniform(50) + 10,
        throughput: state.message_rate,
        error_rate: :rand.uniform(5) / 100.0
      }
    }
    
    {:ok, {:performance_metrics, message}}
  end

  defp send_message({message_type, payload}, state) do
    try do
      case P2PProtocol.broadcast_message(state.cluster_id, message_type, payload) do
        :ok ->
          :ok
          
        {:error, reason} ->
          Logger.warning("Message broadcast failed: #{inspect(reason)}")
          :error
      end
    catch
      :exit, reason ->
        Logger.warning("Message send crashed: #{inspect(reason)}")
        :error
    end
  end

  defp advance_slot(slot_number, epoch_number) do
    # Advance slot and epoch (8 slots per epoch for testing)
    new_slot = slot_number + 1
    
    if rem(new_slot, 8) == 0 do
      {new_slot, epoch_number + 1}
    else
      new_slot
    end
  end

  defp generate_random_hash() do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  defp generate_bls_signature() do
    # Generate mock BLS signature (96 bytes)
    :crypto.strong_rand_bytes(96) |> Base.encode16(case: :lower)
  end

  defp generate_random_bitfield(bits) do
    byte_count = div(bits + 7, 8)
    :crypto.strong_rand_bytes(byte_count) |> Base.encode16(case: :lower)
  end
end