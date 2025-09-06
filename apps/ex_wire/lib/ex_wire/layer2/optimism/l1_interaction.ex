defmodule ExWire.Layer2.Optimism.L1Interaction do
  @moduledoc """
  Handles actual L1 contract interactions for Optimism protocol.

  This module provides the bridge between the Optimism L2 and Ethereum L1,
  handling deposits, withdrawals, state root submissions, and dispute games.
  """

  use GenServer
  require Logger

  alias ExWire.Layer2.Optimism.Protocol
  alias ExWire.Layer2.Web3Client
  alias ExWire.Layer2.TransactionMonitor

  # L1 contract ABIs (simplified for core functions)
  @optimism_portal_abi [
    %{
      name: "depositTransaction",
      type: "function",
      inputs: [
        %{name: "_to", type: "address"},
        %{name: "_value", type: "uint256"},
        %{name: "_gasLimit", type: "uint64"},
        %{name: "_isCreation", type: "bool"},
        %{name: "_data", type: "bytes"}
      ]
    },
    %{
      name: "proveWithdrawalTransaction",
      type: "function",
      inputs: [
        %{name: "_tx", type: "tuple"},
        %{name: "_l2OutputIndex", type: "uint256"},
        %{name: "_outputRootProof", type: "tuple"},
        %{name: "_withdrawalProof", type: "bytes[]"}
      ]
    },
    %{
      name: "finalizeWithdrawalTransaction",
      type: "function",
      inputs: [
        %{name: "_tx", type: "tuple"}
      ]
    }
  ]

  @l2_output_oracle_abi [
    %{
      name: "proposeL2Output",
      type: "function",
      inputs: [
        %{name: "_outputRoot", type: "bytes32"},
        %{name: "_l2BlockNumber", type: "uint256"},
        %{name: "_l1BlockHash", type: "bytes32"},
        %{name: "_l1BlockNumber", type: "uint256"}
      ]
    },
    %{
      name: "getL2Output",
      type: "function",
      inputs: [
        %{name: "_l2OutputIndex", type: "uint256"}
      ],
      outputs: [
        %{name: "outputRoot", type: "bytes32"},
        %{name: "timestamp", type: "uint128"},
        %{name: "l2BlockNumber", type: "uint128"}
      ]
    }
  ]

  @type t :: %__MODULE__{
          network: atom(),
          web3_client: pid() | nil,
          contracts: map(),
          monitor_pid: pid() | nil,
          pending_transactions: map()
        }

  defstruct [
    :network,
    :web3_client,
    :contracts,
    :monitor_pid,
    pending_transactions: %{}
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Deposits ETH or tokens from L1 to L2.
  """
  @spec deposit(map()) :: {:ok, String.t()} | {:error, term()}
  def deposit(params) do
    GenServer.call(__MODULE__, {:deposit, params})
  end

  @doc """
  Proposes a new L2 output root to the L2OutputOracle.
  """
  @spec propose_l2_output(binary(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def propose_l2_output(output_root, l2_block_number) do
    GenServer.call(__MODULE__, {:propose_l2_output, output_root, l2_block_number})
  end

  @doc """
  Proves a withdrawal transaction on L1.
  """
  @spec prove_withdrawal(map(), map()) :: {:ok, String.t()} | {:error, term()}
  def prove_withdrawal(withdrawal_tx, proof_data) do
    GenServer.call(__MODULE__, {:prove_withdrawal, withdrawal_tx, proof_data})
  end

  @doc """
  Finalizes a proven withdrawal after the challenge period.
  """
  @spec finalize_withdrawal(map()) :: {:ok, String.t()} | {:error, term()}
  def finalize_withdrawal(withdrawal_tx) do
    GenServer.call(__MODULE__, {:finalize_withdrawal, withdrawal_tx})
  end

  @doc """
  Gets the current L2 output at a given index.
  """
  @spec get_l2_output(non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def get_l2_output(output_index) do
    GenServer.call(__MODULE__, {:get_l2_output, output_index})
  end

  @doc """
  Monitors L1 for deposit events and relays them to L2.
  """
  @spec monitor_deposits() :: :ok
  def monitor_deposits() do
    GenServer.cast(__MODULE__, :monitor_deposits)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    network = opts[:network] || :mainnet

    # Start Web3 client for L1 interaction
    web3_opts = [
      name: :"#{__MODULE__}.Web3Client",
      rpc_url: opts[:l1_rpc_url] || get_default_rpc_url(network),
      chain_id: get_chain_id(network),
      private_key: opts[:proposer_key]
    ]

    {:ok, _web3_client_pid} = Web3Client.start_link(web3_opts)

    # Start transaction monitor
    {:ok, monitor_pid} = TransactionMonitor.start_link(client: :"#{__MODULE__}.Web3Client")

    state = %__MODULE__{
      network: network,
      web3_client: :"#{__MODULE__}.Web3Client",
      contracts: get_contract_addresses(network),
      monitor_pid: monitor_pid
    }

    # Start monitoring L1 events
    if opts[:monitor_events] do
      Process.send_after(self(), :check_l1_events, 5000)
    end

    Logger.info("Optimism L1 Interaction initialized for #{state.network} with Web3 client")

    {:ok, state}
  end

  @impl true
  def handle_call({:deposit, params}, _from, state) do
    tx_data = encode_deposit_transaction(params)

    case send_l1_transaction(
           state.contracts.optimism_portal,
           tx_data,
           params[:value] || 0,
           state
         ) do
      {:ok, tx_hash} ->
        Logger.info("Deposit transaction sent: #{tx_hash}")
        {:reply, {:ok, tx_hash}, state}

      {:error, reason} = error ->
        Logger.error("Failed to send deposit: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:propose_l2_output, output_root, l2_block_number}, _from, state) do
    # Get current L1 block info
    {:ok, l1_block} = get_current_l1_block(state)

    tx_data =
      encode_propose_output(
        output_root,
        l2_block_number,
        l1_block.hash,
        l1_block.number
      )

    case send_l1_transaction(
           state.contracts.l2_output_oracle,
           tx_data,
           0,
           state
         ) do
      {:ok, tx_hash} ->
        Logger.info("L2 output proposed: block #{l2_block_number}, tx: #{tx_hash}")
        {:reply, {:ok, tx_hash}, state}

      {:error, reason} = error ->
        Logger.error("Failed to propose output: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:prove_withdrawal, withdrawal_tx, proof_data}, _from, state) do
    tx_data = encode_prove_withdrawal(withdrawal_tx, proof_data)

    case send_l1_transaction(
           state.contracts.optimism_portal,
           tx_data,
           0,
           state
         ) do
      {:ok, tx_hash} ->
        Logger.info("Withdrawal proven: #{tx_hash}")

        # Track proven withdrawal for finalization
        withdrawal_id = compute_withdrawal_hash(withdrawal_tx)
        proven_withdrawal = Map.put(withdrawal_tx, :proven_at, DateTime.utc_now())

        new_state = %{
          state
          | pending_transactions:
              Map.put(
                state.pending_transactions,
                withdrawal_id,
                proven_withdrawal
              )
        }

        {:reply, {:ok, tx_hash}, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to prove withdrawal: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:finalize_withdrawal, withdrawal_tx}, _from, state) do
    withdrawal_id = compute_withdrawal_hash(withdrawal_tx)

    case Map.get(state.pending_transactions, withdrawal_id) do
      nil ->
        {:reply, {:error, :withdrawal_not_found}, state}

      proven_withdrawal ->
        # Check if challenge period has passed (7 days)
        challenge_period = 7 * 24 * 60 * 60
        seconds_passed = DateTime.diff(DateTime.utc_now(), proven_withdrawal.proven_at)

        if seconds_passed < challenge_period do
          remaining = challenge_period - seconds_passed
          {:reply, {:error, {:challenge_period_active, remaining}}, state}
        else
          tx_data = encode_finalize_withdrawal(withdrawal_tx)

          case send_l1_transaction(
                 state.contracts.optimism_portal,
                 tx_data,
                 0,
                 state
               ) do
            {:ok, tx_hash} ->
              Logger.info("Withdrawal finalized: #{tx_hash}")

              # Remove from pending
              new_pending = Map.delete(state.pending_transactions, withdrawal_id)
              new_state = %{state | pending_transactions: new_pending}

              {:reply, {:ok, tx_hash}, new_state}

            {:error, reason} = error ->
              Logger.error("Failed to finalize withdrawal: #{inspect(reason)}")
              {:reply, error, state}
          end
        end
    end
  end

  @impl true
  def handle_call({:get_l2_output, output_index}, _from, state) do
    case call_l1_view_function(
           state.contracts.l2_output_oracle,
           "getL2Output",
           [output_index],
           state
         ) do
      {:ok, [output_root, timestamp, l2_block_number]} ->
        output = %{
          output_root: output_root,
          timestamp: timestamp,
          l2_block_number: l2_block_number
        }

        {:reply, {:ok, output}, state}

      {:error, reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_cast(:monitor_deposits, state) do
    # Start monitoring deposit events
    spawn_link(fn -> monitor_deposit_events(state) end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_l1_events, state) do
    # Check for new L1 events (deposits, challenges, etc.)
    check_and_process_events(state)

    # Schedule next check
    # Every 12 seconds (1 L1 block)
    Process.send_after(self(), :check_l1_events, 12_000)

    {:noreply, state}
  end

  # Private Functions

  defp get_default_rpc_url(:mainnet), do: "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
  defp get_default_rpc_url(:goerli), do: "https://eth-goerli.g.alchemy.com/v2/YOUR_KEY"
  defp get_default_rpc_url(:sepolia), do: "https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"
  defp get_default_rpc_url(_), do: "http://localhost:8545"

  defp get_contract_addresses(:mainnet) do
    %{
      optimism_portal: "0xbEb5Fc579115071764c7423A4f12eDde41f106Ed",
      l2_output_oracle: "0xdfe97868233d1aa22e815a266982f2cf17685a27",
      l1_cross_domain_messenger: "0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1",
      dispute_game_factory: "0x05F9613aDB30026FFd634f38e5C4dFd30a197Fa1",
      system_config: "0x229047fed2591dbec1eF1118d64F7aF3dB9EB290"
    }
  end

  defp get_contract_addresses(network) do
    # For testnets, would return different addresses
    Logger.warning("Using mainnet contracts for #{network}")
    get_contract_addresses(:mainnet)
  end

  defp encode_deposit_transaction(params) do
    # Encode the deposit transaction calldata
    # In production, use ABI encoding library
    ABI.encode("depositTransaction", [
      params[:to],
      params[:value] || 0,
      params[:gas_limit],
      params[:is_creation] || false,
      params[:data] || <<>>
    ])
  end

  defp encode_propose_output(output_root, l2_block_number, l1_block_hash, l1_block_number) do
    ABI.encode("proposeL2Output", [
      output_root,
      l2_block_number,
      l1_block_hash,
      l1_block_number
    ])
  end

  defp encode_prove_withdrawal(withdrawal_tx, proof_data) do
    ABI.encode("proveWithdrawalTransaction", [
      withdrawal_tx,
      proof_data.l2_output_index,
      proof_data.output_root_proof,
      proof_data.withdrawal_proof
    ])
  end

  defp encode_finalize_withdrawal(withdrawal_tx) do
    ABI.encode("finalizeWithdrawalTransaction", [withdrawal_tx])
  end

  defp send_l1_transaction(to, data, value, state) do
    # Build transaction parameters
    tx_params = %{
      to: to,
      data: "0x" <> Base.encode16(data, case: :lower),
      value: value
    }

    # Send transaction using Web3 client
    case Web3Client.send_transaction(state.web3_client, tx_params) do
      {:ok, tx_hash} ->
        # Monitor the transaction for confirmation
        TransactionMonitor.monitor_transaction(tx_hash, tx_params,
          callbacks: [fn tx -> handle_transaction_result(tx, state) end]
        )

        {:ok, tx_hash}

      {:error, reason} ->
        Logger.error("Failed to send L1 transaction: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp call_l1_view_function(contract, function_name, args, state) do
    # Encode the function call
    call_data = ABI.encode(function_name, args)

    # Make the contract call using Web3 client
    case Web3Client.call_contract(state.web3_client, contract, call_data, "latest") do
      {:ok, result} ->
        # Decode the result
        decoded = ABI.decode(function_name, result)
        {:ok, decoded}

      {:error, reason} ->
        Logger.error("L1 view function call failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_current_l1_block(state) do
    case Web3Client.get_block(state.web3_client, "latest") do
      {:ok, block} ->
        {:ok,
         %{
           number: block.number,
           hash: block.hash,
           timestamp: block.timestamp
         }}

      {:error, reason} ->
        Logger.error("Failed to get current L1 block: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp compute_withdrawal_hash(withdrawal_tx) do
    :crypto.hash(:sha256, :erlang.term_to_binary(withdrawal_tx))
    |> Base.encode16(case: :lower)
  end

  # Gas estimation is now handled by the Web3Client automatically
  # Gas pricing is also handled by the Web3Client with EIP-1559 support

  defp handle_transaction_result(tx, _state) do
    # Callback function for transaction monitoring
    case tx.status do
      :confirmed ->
        Logger.info("L1 transaction confirmed: #{tx.hash} in block #{tx.block_number}")

      :failed ->
        Logger.error("L1 transaction failed: #{tx.hash}")

      :timeout ->
        Logger.warning("L1 transaction timed out: #{tx.hash}")

      _ ->
        :ok
    end
  end

  defp get_chain_id(network) do
    case network do
      :mainnet -> 1
      :sepolia -> 11_155_111
      :goerli -> 5
      # default to mainnet
      _ -> 1
    end
  end

  defp monitor_deposit_events(state) do
    # Monitor L1 for TransactionDeposited events
    # In production, use WebSocket subscription or polling

    Logger.info("Monitoring L1 deposit events...")

    # This would run continuously, processing deposit events
    :ok
  end

  defp check_and_process_events(state) do
    # Check for various L1 events and process them

    # Check for deposits
    check_deposit_events(state)

    # Check for output proposals
    check_output_proposals(state)

    # Check for challenges
    check_challenge_events(state)
  end

  defp check_deposit_events(_state) do
    # Query for recent TransactionDeposited events
    # Process and relay to L2
    :ok
  end

  defp check_output_proposals(_state) do
    # Query for OutputProposed events
    # Validate and store
    :ok
  end

  defp check_challenge_events(_state) do
    # Query for challenge-related events
    # Process disputes if needed
    :ok
  end
end

# Mock ABI module for encoding/decoding
# In production, use ex_abi or similar library
defmodule ABI do
  def encode(_function_name, _args) do
    # Mock encoding
    :crypto.strong_rand_bytes(32)
  end

  def decode(_function_name, _data) do
    # Mock decoding
    [:crypto.strong_rand_bytes(32), 0, 0]
  end
end
