defmodule ExWire.Layer2.Bridge.CrossLayerBridge do
  @moduledoc """
  Cross-layer bridge for communication between L1 and L2.

  Handles:
  - Asset deposits from L1 to L2
  - Withdrawals from L2 to L1
  - Arbitrary message passing
  - State synchronization
  - Event propagation
  """

  use GenServer
  require Logger

  alias ExWire.Layer2.Bridge.{MessageQueue, EventRelay}

  @type layer :: :l1 | :l2
  @type message_status :: :pending | :relayed | :confirmed | :failed

  @type bridge_message :: %{
          id: String.t(),
          from_layer: layer(),
          to_layer: layer(),
          sender: binary(),
          target: binary(),
          data: binary(),
          value: non_neg_integer(),
          nonce: non_neg_integer(),
          timestamp: DateTime.t()
        }

  @type t :: %__MODULE__{
          bridge_id: String.t(),
          l1_contract: binary(),
          l2_contract: binary(),
          message_queue: MessageQueue.t(),
          pending_deposits: map(),
          pending_withdrawals: map(),
          relayed_messages: map(),
          asset_mappings: map()
        }

  defstruct [
    :bridge_id,
    :l1_contract,
    :l2_contract,
    :message_queue,
    pending_deposits: %{},
    pending_withdrawals: %{},
    relayed_messages: %{},
    asset_mappings: %{}
  ]

  # Client API

  @doc """
  Starts a cross-layer bridge.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:bridge_id]))
  end

  @doc """
  Initiates a deposit from L1 to L2.
  """
  @spec deposit(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def deposit(bridge_id, deposit_params) do
    GenServer.call(via_tuple(bridge_id), {:deposit, deposit_params})
  end

  @doc """
  Initiates a withdrawal from L2 to L1.
  """
  @spec withdraw(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def withdraw(bridge_id, withdrawal_params) do
    GenServer.call(via_tuple(bridge_id), {:withdraw, withdrawal_params})
  end

  @doc """
  Sends an arbitrary message across layers.
  """
  @spec send_message(String.t(), layer(), layer(), binary(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  def send_message(bridge_id, from_layer, to_layer, target, data) do
    GenServer.call(via_tuple(bridge_id), {:send_message, from_layer, to_layer, target, data})
  end

  @doc """
  Relays a pending message to its destination layer.
  """
  @spec relay_message(String.t(), String.t()) :: {:ok, :relayed} | {:error, term()}
  def relay_message(bridge_id, message_id) do
    GenServer.call(via_tuple(bridge_id), {:relay_message, message_id})
  end

  @doc """
  Confirms that a message was successfully processed on the destination layer.
  """
  @spec confirm_message(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def confirm_message(bridge_id, message_id, receipt) do
    GenServer.call(via_tuple(bridge_id), {:confirm_message, message_id, receipt})
  end

  @doc """
  Gets the status of a bridge message.
  """
  @spec get_message_status(String.t(), String.t()) ::
          {:ok, message_status()} | {:error, :not_found}
  def get_message_status(bridge_id, message_id) do
    GenServer.call(via_tuple(bridge_id), {:get_message_status, message_id})
  end

  @doc """
  Proves inclusion of a message in the source layer.
  """
  @spec prove_message_inclusion(String.t(), String.t(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def prove_message_inclusion(bridge_id, message_id, state_root) do
    GenServer.call(via_tuple(bridge_id), {:prove_inclusion, message_id, state_root})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting Cross-Layer Bridge: #{opts[:bridge_id]}")

    # Initialize message queue
    {:ok, message_queue} = MessageQueue.new()

    # Load asset mappings (L1 token -> L2 token)
    asset_mappings = load_asset_mappings(opts[:config])

    state = %__MODULE__{
      bridge_id: opts[:bridge_id],
      l1_contract: opts[:l1_contract],
      l2_contract: opts[:l2_contract],
      message_queue: message_queue,
      asset_mappings: asset_mappings
    }

    # Start event monitoring for both layers
    start_event_monitoring(state)

    # Schedule periodic message relay
    Process.send_after(self(), :relay_pending_messages, 5_000)

    {:ok, state}
  end

  @impl true
  def handle_call({:deposit, params}, _from, state) do
    deposit_id = generate_deposit_id()

    deposit = %{
      id: deposit_id,
      from: params[:from],
      # Same address on L2 by default
      to: params[:to] || params[:from],
      token: params[:token],
      amount: params[:amount],
      l2_token: Map.get(state.asset_mappings, params[:token]),
      data: params[:data] || <<>>,
      timestamp: DateTime.utc_now(),
      status: :pending,
      l1_block: get_current_l1_block(),
      l1_tx_hash: nil
    }

    # Create bridge message for the deposit
    message =
      create_bridge_message(
        :l1,
        :l2,
        deposit.from,
        deposit.to,
        encode_deposit_data(deposit),
        deposit.amount
      )

    # Queue the message
    {:ok, updated_queue} = MessageQueue.enqueue(state.message_queue, message)

    new_pending_deposits = Map.put(state.pending_deposits, deposit_id, deposit)

    Logger.info("Deposit initiated: #{deposit_id} - #{deposit.amount} #{inspect(deposit.token)}")

    {:reply, {:ok, deposit_id},
     %{state | pending_deposits: new_pending_deposits, message_queue: updated_queue}}
  end

  @impl true
  def handle_call({:withdraw, params}, _from, state) do
    withdrawal_id = generate_withdrawal_id()

    withdrawal = %{
      id: withdrawal_id,
      from: params[:from],
      # Same address on L1 by default
      to: params[:to] || params[:from],
      l2_token: params[:token],
      l1_token: get_l1_token(state.asset_mappings, params[:token]),
      amount: params[:amount],
      data: params[:data] || <<>>,
      timestamp: DateTime.utc_now(),
      status: :pending,
      l2_block: get_current_l2_block(),
      merkle_proof: params[:proof]
    }

    # Create bridge message for the withdrawal
    message =
      create_bridge_message(
        :l2,
        :l1,
        withdrawal.from,
        withdrawal.to,
        encode_withdrawal_data(withdrawal),
        withdrawal.amount
      )

    # Queue the message
    {:ok, updated_queue} = MessageQueue.enqueue(state.message_queue, message)

    new_pending_withdrawals = Map.put(state.pending_withdrawals, withdrawal_id, withdrawal)

    Logger.info(
      "Withdrawal initiated: #{withdrawal_id} - #{withdrawal.amount} #{inspect(withdrawal.l2_token)}"
    )

    {:reply, {:ok, withdrawal_id},
     %{state | pending_withdrawals: new_pending_withdrawals, message_queue: updated_queue}}
  end

  @impl true
  def handle_call({:send_message, from_layer, to_layer, target, data}, _from, state) do
    message_id = generate_message_id()

    message = %{
      id: message_id,
      from_layer: from_layer,
      to_layer: to_layer,
      sender: get_caller_address(),
      target: target,
      data: data,
      value: 0,
      nonce: get_next_nonce(state),
      timestamp: DateTime.utc_now(),
      status: :pending
    }

    # Queue the message
    {:ok, updated_queue} = MessageQueue.enqueue(state.message_queue, message)

    new_relayed_messages = Map.put(state.relayed_messages, message_id, message)

    Logger.info("Message queued: #{message_id} from #{from_layer} to #{to_layer}")

    {:reply, {:ok, message_id},
     %{state | relayed_messages: new_relayed_messages, message_queue: updated_queue}}
  end

  @impl true
  def handle_call({:relay_message, message_id}, _from, state) do
    case Map.get(state.relayed_messages, message_id) do
      nil ->
        {:reply, {:error, :message_not_found}, state}

      message when message.status != :pending ->
        {:reply, {:error, :message_already_relayed}, state}

      message ->
        case relay_to_destination(message, state) do
          {:ok, tx_hash} ->
            updated_message =
              Map.merge(message, %{
                status: :relayed,
                relay_tx_hash: tx_hash,
                relayed_at: DateTime.utc_now()
              })

            new_relayed_messages = Map.put(state.relayed_messages, message_id, updated_message)

            Logger.info("Message relayed: #{message_id} with tx #{Base.encode16(tx_hash)}")

            {:reply, {:ok, :relayed}, %{state | relayed_messages: new_relayed_messages}}

          {:error, reason} = error ->
            Logger.error("Failed to relay message #{message_id}: #{inspect(reason)}")
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:confirm_message, message_id, receipt}, _from, state) do
    case Map.get(state.relayed_messages, message_id) do
      nil ->
        {:reply, {:error, :message_not_found}, state}

      message ->
        updated_message =
          Map.merge(message, %{
            status: :confirmed,
            confirmation_receipt: receipt,
            confirmed_at: DateTime.utc_now()
          })

        new_relayed_messages = Map.put(state.relayed_messages, message_id, updated_message)

        # Update deposit/withdrawal status if applicable
        new_state = update_transfer_status(message_id, :confirmed, state)

        Logger.info("Message confirmed: #{message_id}")

        {:reply, :ok, %{new_state | relayed_messages: new_relayed_messages}}
    end
  end

  @impl true
  def handle_call({:get_message_status, message_id}, _from, state) do
    case Map.get(state.relayed_messages, message_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      message ->
        {:reply, {:ok, message.status}, state}
    end
  end

  @impl true
  def handle_call({:prove_inclusion, message_id, state_root}, _from, state) do
    case Map.get(state.relayed_messages, message_id) do
      nil ->
        {:reply, {:error, :message_not_found}, state}

      message ->
        # Generate merkle proof for message inclusion
        case generate_inclusion_proof(message, state_root) do
          {:ok, proof} ->
            {:reply, {:ok, proof}, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_info(:relay_pending_messages, state) do
    # Relay pending messages in the queue
    case MessageQueue.get_pending(state.message_queue, 10) do
      [] ->
        Process.send_after(self(), :relay_pending_messages, 5_000)
        {:noreply, state}

      messages ->
        # Relay messages in parallel
        Enum.each(messages, fn message ->
          Task.start(fn ->
            relay_message(state.bridge_id, message.id)
          end)
        end)

        Process.send_after(self(), :relay_pending_messages, 5_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:l1_event, event}, state) do
    # Handle L1 events (deposits, message sends)
    new_state = process_l1_event(event, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:l2_event, event}, state) do
    # Handle L2 events (withdrawals, message sends)
    new_state = process_l2_event(event, state)
    {:noreply, new_state}
  end

  # Private Functions

  defp via_tuple(bridge_id) do
    {:via, Registry, {ExWire.Layer2.BridgeRegistry, bridge_id}}
  end

  defp generate_deposit_id() do
    "deposit_" <> Base.encode16(:crypto.strong_rand_bytes(16))
  end

  defp generate_withdrawal_id() do
    "withdrawal_" <> Base.encode16(:crypto.strong_rand_bytes(16))
  end

  defp generate_message_id() do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(16))
  end

  defp load_asset_mappings(config) do
    # Load L1 -> L2 token mappings
    config[:asset_mappings] ||
      %{
        # ETH doesn't need mapping
        <<0::160>> => <<0::160>>,
        # Example: USDC L1 -> USDC L2
        <<1::160>> => <<1001::160>>,
        # Example: DAI L1 -> DAI L2  
        <<2::160>> => <<1002::160>>
      }
  end

  defp get_l1_token(mappings, l2_token) do
    # Reverse lookup L2 -> L1
    mappings
    |> Enum.find(fn {_l1, l2} -> l2 == l2_token end)
    |> case do
      {l1_token, _} -> l1_token
      nil -> nil
    end
  end

  defp create_bridge_message(from_layer, to_layer, sender, target, data, value) do
    %{
      id: generate_message_id(),
      from_layer: from_layer,
      to_layer: to_layer,
      sender: sender,
      target: target,
      data: data,
      value: value,
      nonce: :rand.uniform(1_000_000),
      timestamp: DateTime.utc_now(),
      status: :pending
    }
  end

  defp encode_deposit_data(deposit) do
    # Encode deposit data for bridge message
    # This would use RLP or ABI encoding in production
    :erlang.term_to_binary(deposit)
  end

  defp encode_withdrawal_data(withdrawal) do
    # Encode withdrawal data for bridge message
    :erlang.term_to_binary(withdrawal)
  end

  defp get_caller_address() do
    # Get caller from process dictionary or default
    Process.get(:tx_sender, <<0::160>>)
  end

  defp get_next_nonce(state) do
    map_size(state.relayed_messages) + 1
  end

  defp get_current_l1_block() do
    # Get current L1 block from blockchain module
    case Blockchain.get_latest_block_number() do
      {:ok, block_num} -> block_num
      _ -> 0
    end
  end

  defp get_current_l2_block() do
    # Get current L2 block from rollup module
    case ExWire.Layer2.Rollup.get_latest_batch_number() do
      {:ok, batch_num} -> batch_num
      _ -> 0
    end
  end

  defp relay_to_destination(message, state) do
    # Relay message to destination layer
    case message.to_layer do
      :l1 ->
        # Send to L1 contract
        send_to_l1(message, state.l1_contract)

      :l2 ->
        # Send to L2 contract
        send_to_l2(message, state.l2_contract)
    end
  end

  defp send_to_l1(message, l1_contract) do
    # Send transaction to L1 via L1ContractInterface
    Logger.debug("Sending message to L1 contract #{Base.encode16(l1_contract)}")

    ExWire.Layer2.L1ContractInterface.call_contract(
      l1_contract,
      :relay_message,
      [message.from, message.to, message.data, message.nonce]
    )
  end

  defp send_to_l2(message, l2_contract) do
    # Send transaction to L2 via rollup interface
    Logger.debug("Sending message to L2 contract #{Base.encode16(l2_contract)}")

    ExWire.Layer2.Rollup.submit_transaction(%{
      to: l2_contract,
      from: message.from,
      data: message.data,
      value: message.value
    })
  end

  defp generate_inclusion_proof(message, state_root) do
    # Generate merkle proof for message inclusion
    MerkleTree.generate_proof(
      state_root,
      ExthCrypto.Hash.Keccac.kec(message.data),
      message.nonce
    )
  end

  defp update_transfer_status(message_id, status, state) do
    # Update deposit or withdrawal status based on message confirmation
    state
  end

  defp start_event_monitoring(state) do
    # Start monitoring L1 and L2 events
    EventRelay.start_monitoring(self(), state.l1_contract, :l1)
    EventRelay.start_monitoring(self(), state.l2_contract, :l2)
  end

  defp process_l1_event(event, state) do
    Logger.debug("Processing L1 event: #{inspect(event)}")

    # Process different L1 event types
    case event.type do
      :deposit_initiated ->
        # Track new deposit from L1
        Map.update(state, :pending_deposits, [event], &[event | &1])

      :withdrawal_finalized ->
        # Mark withdrawal as complete
        Map.update(state, :relayed_messages, %{}, &Map.put(&1, event.message_id, :finalized))

      _ ->
        state
    end
  end

  defp process_l2_event(event, state) do
    Logger.debug("Processing L2 event: #{inspect(event)}")

    # Process different L2 event types  
    case event.type do
      :withdrawal_initiated ->
        # Track new withdrawal from L2
        Map.update(state, :pending_withdrawals, [event], &[event | &1])

      :deposit_finalized ->
        # Mark deposit as complete
        Map.update(state, :relayed_messages, %{}, &Map.put(&1, event.message_id, :finalized))

      _ ->
        state
    end
  end
end
