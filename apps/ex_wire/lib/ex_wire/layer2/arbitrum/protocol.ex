defmodule ExWire.Layer2.Arbitrum.Protocol do
  @moduledoc """
  Arbitrum protocol implementation following Nitro specifications.

  Implements the core Arbitrum protocol including:
  - Rollup contract interactions for assertion posting
  - Inbox/Outbox for L1-L2 messaging
  - Challenge manager for interactive fraud proofs
  - Sequencer message batching and compression
  - Fast withdrawal via liquidity providers
  """

  use GenServer
  require Logger

  alias ExWire.Layer2.{StateCommitment, Batch}

  # Arbitrum One mainnet contracts
  @l1_contracts %{
    rollup: "0x5eF0D09d1E6204141B4d37530808eD19f60FBa35",
    inbox: "0x4Dbd4fc535Ac27206064B68FfCf827b0A60BAB3f",
    outbox: "0x0B9857ae2D4A3DBe74ffE1d7DF045bb7F96E4840",
    bridge: "0x8315177aB297bA92A06054cE80a67Ed4DBd7ed3a",
    sequencer_inbox: "0x1c479675ad559DC151F6Ec7ed3FbF8ceE79582B6",
    challenge_manager: "0xe5896783a2F463446E1f624e64Aa6836BE4C6f58"
  }

  # L2 predeploys
  @l2_contracts %{
    arbsys: "0x0000000000000000000000000000000000000064",
    arbretryable_tx: "0x000000000000000000000000000000000000006E",
    arbgas_info: "0x000000000000000000000000000000000000006C",
    node_interface: "0x00000000000000000000000000000000000000C8"
  }

  # Protocol constants
  # ~7 days at 13.2s/block
  @confirmation_period_blocks 45_818
  @challenge_period_blocks 45_818
  # blocks
  @min_assertion_period 75
  @data_availability_committee_size 6

  @type assertion_status :: :pending | :confirmed | :challenged | :rejected

  @type t :: %__MODULE__{
          network: :mainnet | :nova | :goerli,
          l1_contracts: map(),
          l2_contracts: map(),
          latest_assertion: map(),
          pending_messages: list(),
          sequencer_batches: list(),
          validators: map(),
          staker_address: binary() | nil
        }

  defstruct [
    :network,
    :l1_contracts,
    :l2_contracts,
    :latest_assertion,
    :staker_address,
    pending_messages: [],
    sequencer_batches: [],
    validators: %{}
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Posts a new assertion (RBlock) to the rollup contract.
  Used by validators to advance the chain.
  """
  @spec post_assertion(map()) :: {:ok, String.t()} | {:error, term()}
  def post_assertion(assertion_data) do
    GenServer.call(__MODULE__, {:post_assertion, assertion_data})
  end

  @doc """
  Sends a message from L1 to L2 through the inbox.
  Creates a retryable ticket on L2.
  """
  @spec send_l1_to_l2_message(map()) :: {:ok, String.t()} | {:error, term()}
  def send_l1_to_l2_message(message_params) do
    GenServer.call(__MODULE__, {:send_l1_to_l2_message, message_params})
  end

  @doc """
  Sends a message from L2 to L1 through ArbSys.
  Message can be executed on L1 after confirmation.
  """
  @spec send_l2_to_l1_message(map()) :: {:ok, String.t()} | {:error, term()}
  def send_l2_to_l1_message(message_params) do
    GenServer.call(__MODULE__, {:send_l2_to_l1_message, message_params})
  end

  @doc """
  Executes an L2-to-L1 message after the assertion is confirmed.
  """
  @spec execute_l2_to_l1_message(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def execute_l2_to_l1_message(message_id, proof) do
    GenServer.call(__MODULE__, {:execute_l2_to_l1_message, message_id, proof})
  end

  @doc """
  Submits a batch of sequencer messages for data availability.
  Used by the sequencer to post transaction batches.
  """
  @spec submit_sequencer_batch(list(binary())) :: {:ok, non_neg_integer()} | {:error, term()}
  def submit_sequencer_batch(messages) do
    GenServer.call(__MODULE__, {:submit_sequencer_batch, messages})
  end

  @doc """
  Initiates a challenge against an assertion.
  Starts the interactive fraud proof game.
  """
  @spec challenge_assertion(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def challenge_assertion(assertion_hash, challenge_data) do
    GenServer.call(__MODULE__, {:challenge_assertion, assertion_hash, challenge_data})
  end

  @doc """
  Makes a move in an ongoing challenge game.
  Part of the interactive fraud proof protocol.
  """
  @spec bisect_challenge(String.t(), non_neg_integer(), binary()) ::
          {:ok, :move_made} | {:error, term()}
  def bisect_challenge(challenge_id, segment_index, proof) do
    GenServer.call(__MODULE__, {:bisect_challenge, challenge_id, segment_index, proof})
  end

  @doc """
  Claims a stake to become a validator.
  Requires staking ETH as collateral.
  """
  @spec stake(non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  def stake(amount) do
    GenServer.call(__MODULE__, {:stake, amount})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    network = opts[:network] || :mainnet

    state = %__MODULE__{
      network: network,
      l1_contracts: get_contracts_for_network(network, :l1),
      l2_contracts: get_contracts_for_network(network, :l2),
      staker_address: opts[:staker_address]
    }

    # Schedule periodic tasks
    schedule_assertion_check()
    schedule_batch_submission()

    Logger.info("Arbitrum protocol initialized for network: #{network}")

    {:ok, state}
  end

  @impl true
  def handle_call({:post_assertion, assertion_data}, _from, state) do
    assertion = build_assertion(assertion_data, state)

    case validate_assertion(assertion, state) do
      :ok ->
        assertion_hash = hash_assertion(assertion)

        # In production, would submit to L1 rollup contract
        new_state = %{state | latest_assertion: assertion}

        Logger.info("Assertion posted: #{Base.encode16(assertion_hash)}")

        {:reply, {:ok, Base.encode16(assertion_hash)}, new_state}

      {:error, reason} = error ->
        Logger.error("Invalid assertion: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:send_l1_to_l2_message, params}, _from, state) do
    # Create retryable ticket
    ticket = %{
      from: params[:from],
      to: params[:to],
      l2_call_value: params[:value] || 0,
      deposit: params[:deposit],
      max_submission_fee: params[:max_submission_fee],
      gas_limit: params[:gas_limit],
      max_fee_per_gas: params[:max_fee_per_gas],
      data: params[:data] || <<>>
    }

    ticket_id = create_retryable_ticket_id(ticket)

    Logger.info("L1→L2 message created: #{Base.encode16(ticket_id)}")

    {:reply, {:ok, Base.encode16(ticket_id)}, state}
  end

  @impl true
  def handle_call({:send_l2_to_l1_message, params}, _from, state) do
    message = %{
      sender: params[:from],
      target: params[:to],
      value: params[:value] || 0,
      data: params[:data] || <<>>,
      timestamp: DateTime.utc_now(),
      l2_block: params[:l2_block]
    }

    message_id = hash_l2_to_l1_message(message)

    new_state = %{state | pending_messages: [message | state.pending_messages]}

    Logger.info("L2→L1 message queued: #{Base.encode16(message_id)}")

    {:reply, {:ok, Base.encode16(message_id)}, new_state}
  end

  @impl true
  def handle_call({:execute_l2_to_l1_message, message_id, proof}, _from, state) do
    case find_message(message_id, state) do
      nil ->
        {:reply, {:error, :message_not_found}, state}

      message ->
        case verify_message_proof(message, proof) do
          {:ok, true} ->
            # Execute the message on L1
            result = execute_on_l1(message)

            Logger.info("L2→L1 message executed: #{message_id}")

            {:reply, {:ok, result}, state}

          {:ok, false} ->
            {:reply, {:error, :invalid_proof}, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:submit_sequencer_batch, messages}, _from, state) do
    # Compress messages using Brotli compression
    compressed_batch = compress_batch(messages)

    batch = %{
      messages: messages,
      compressed_data: compressed_batch,
      timestamp: DateTime.utc_now(),
      sequencer: get_sequencer_address(state),
      batch_number: length(state.sequencer_batches)
    }

    # Calculate data availability commitment
    da_commitment = calculate_da_commitment(compressed_batch)

    new_state = %{state | sequencer_batches: [batch | state.sequencer_batches]}

    Logger.info(
      "Sequencer batch #{batch.batch_number} submitted: #{byte_size(compressed_batch)} bytes"
    )

    {:reply, {:ok, batch.batch_number}, new_state}
  end

  @impl true
  def handle_call({:challenge_assertion, assertion_hash, challenge_data}, _from, state) do
    challenge_id = generate_challenge_id()

    challenge = %{
      id: challenge_id,
      assertion_hash: assertion_hash,
      challenger: get_challenger_address(state),
      challenge_data: challenge_data,
      created_at: DateTime.utc_now(),
      status: :active,
      bisection_level: 0,
      segments: []
    }

    Logger.info("Challenge initiated: #{challenge_id} against #{assertion_hash}")

    {:reply, {:ok, challenge_id}, state}
  end

  @impl true
  def handle_call({:bisect_challenge, challenge_id, segment_index, proof}, _from, state) do
    # Interactive fraud proof bisection
    # Each round narrows down the disagreement point

    case verify_bisection_proof(challenge_id, segment_index, proof) do
      {:ok, :valid} ->
        Logger.info("Bisection move made in challenge #{challenge_id}")
        {:reply, {:ok, :move_made}, state}

      {:error, reason} = error ->
        Logger.error("Invalid bisection proof: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:stake, amount}, _from, state) do
    if state.staker_address do
      stake_data = %{
        staker: state.staker_address,
        amount: amount,
        timestamp: DateTime.utc_now()
      }

      # Register as validator
      validator = %{
        address: state.staker_address,
        stake: amount,
        latest_assertion: nil,
        status: :active
      }

      new_validators = Map.put(state.validators, state.staker_address, validator)
      new_state = %{state | validators: new_validators}

      Logger.info("Staked #{amount} ETH as validator")

      {:reply, {:ok, state.staker_address}, new_state}
    else
      {:reply, {:error, :no_staker_address}, state}
    end
  end

  @impl true
  def handle_info(:check_assertions, state) do
    # Check for new assertions to validate
    check_pending_assertions(state)
    schedule_assertion_check()
    {:noreply, state}
  end

  @impl true
  def handle_info(:submit_batch, state) do
    # Periodic batch submission by sequencer
    if should_submit_batch?(state) do
      submit_pending_batch(state)
    end

    schedule_batch_submission()
    {:noreply, state}
  end

  # Private Functions

  defp get_contracts_for_network(:mainnet, :l1), do: @l1_contracts
  defp get_contracts_for_network(:mainnet, :l2), do: @l2_contracts

  defp get_contracts_for_network(:nova, :l1) do
    # Arbitrum Nova contracts
    %{
      rollup: "0xFb209827c58283535b744575e11953DCC4bEAD88",
      inbox: "0xc4448b71118c9071Bcb9734A0EAc55D18A153949",
      outbox: "0xD4B80C3D7240325D18E645B49e6535A3Bf95cc58",
      bridge: "0xC1Ebd02f738644983b6C4B2d440b8e77DdE276Bd",
      sequencer_inbox: "0x211E1c4c7f1bF5351Ac850Ed10FD68CFfCF6c21b",
      challenge_manager: "0xA59075221b50C598aED0Eae0bB9869639513af0D"
    }
  end

  defp get_contracts_for_network(:nova, :l2), do: @l2_contracts

  defp get_contracts_for_network(network, layer) do
    Logger.warning("Using mainnet contracts for #{network} #{layer}")
    get_contracts_for_network(:mainnet, layer)
  end

  defp build_assertion(data, state) do
    %{
      state_hash: data[:state_hash],
      challenge_hash: data[:challenge_hash],
      confirmed_hash: data[:confirmed_hash],
      first_child_block: data[:first_child_block],
      last_child_block: data[:last_child_block],
      num_blocks: data[:last_child_block] - data[:first_child_block] + 1,
      staker: state.staker_address,
      timestamp: DateTime.utc_now()
    }
  end

  defp validate_assertion(assertion, state) do
    cond do
      assertion.num_blocks < 1 ->
        {:error, :invalid_block_range}

      assertion.staker == nil ->
        {:error, :no_staker}

      not Map.has_key?(state.validators, assertion.staker) ->
        {:error, :not_validator}

      true ->
        :ok
    end
  end

  defp hash_assertion(assertion) do
    :crypto.hash(:sha256, :erlang.term_to_binary(assertion))
  end

  defp create_retryable_ticket_id(ticket) do
    # Deterministic ticket ID calculation
    data = :erlang.term_to_binary(ticket)
    :crypto.hash(:sha256, data)
  end

  defp hash_l2_to_l1_message(message) do
    :crypto.hash(:sha256, :erlang.term_to_binary(message))
  end

  defp find_message(message_id, state) do
    Enum.find(state.pending_messages, fn msg ->
      hash_l2_to_l1_message(msg) == message_id
    end)
  end

  defp verify_message_proof(_message, proof) do
    # Verify merkle proof of message in outbox
    # Simplified - production would verify actual merkle proof
    if Map.has_key?(proof, :merkle_proof) do
      {:ok, true}
    else
      {:ok, false}
    end
  end

  defp execute_on_l1(message) do
    # Execute the L2→L1 message on L1
    Logger.info("Executing on L1: #{message.target}")
    %{status: :success, gas_used: 50000}
  end

  defp compress_batch(messages) do
    # Use Brotli compression for efficient data availability
    data = :erlang.term_to_binary(messages)
    # Using zlib as Brotli placeholder
    :zlib.compress(data)
  end

  defp calculate_da_commitment(compressed_data) do
    # Calculate data availability commitment
    # Used for Data Availability Committee or on-chain data
    :crypto.hash(:sha256, compressed_data)
  end

  defp get_sequencer_address(_state) do
    # In production, would get from configuration
    <<0::160>>
  end

  defp get_challenger_address(_state) do
    # In production, would get from transaction context
    <<0::160>>
  end

  defp generate_challenge_id() do
    "challenge_" <> Base.encode16(:crypto.strong_rand_bytes(16))
  end

  defp verify_bisection_proof(_challenge_id, _segment_index, proof) do
    # Verify the bisection proof
    # Each bisection narrows down the execution disagreement
    if byte_size(proof) > 0 do
      {:ok, :valid}
    else
      {:error, :invalid_proof}
    end
  end

  defp check_pending_assertions(state) do
    # Check for assertions that need confirmation
    Logger.debug("Checking pending assertions...")

    # In production, would query L1 for assertion status
    :ok
  end

  defp should_submit_batch?(state) do
    # Determine if we should submit a new batch
    # Based on time, batch size, or gas price
    length(state.sequencer_batches) < 100
  end

  defp submit_pending_batch(state) do
    # Submit accumulated messages as a batch
    if length(state.pending_messages) > 0 do
      Logger.info("Submitting batch with #{length(state.pending_messages)} messages")
    end
  end

  defp schedule_assertion_check() do
    # Every minute
    Process.send_after(self(), :check_assertions, 60_000)
  end

  defp schedule_batch_submission() do
    # Every 10 seconds
    Process.send_after(self(), :submit_batch, 10_000)
  end
end
