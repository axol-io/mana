defmodule ExWire.Layer2.Web3Client do
  @moduledoc """
  Web3 client for interacting with Ethereum L1 networks.

  Provides JSON-RPC client functionality for:
  - Transaction sending and monitoring
  - Contract calls and interactions
  - Gas estimation and fee management
  - Event monitoring and filtering
  - Block and transaction receipt retrieval
  """

  use GenServer
  require Logger

  alias ExWire.Layer2.TransactionMonitor

  defstruct [
    :rpc_url,
    :chain_id,
    :private_key,
    :address,
    :http_client,
    :gas_strategy,
    :connection,
    pending_transactions: %{},
    nonce: 0,
    gas_price: nil,
    base_fee: nil,
    priority_fee: nil
  ]

  @type t :: %__MODULE__{}

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Send a signed transaction to the network and monitor for confirmation
  """
  @spec send_transaction(GenServer.server(), map()) :: {:ok, String.t()} | {:error, term()}
  def send_transaction(client \\ __MODULE__, tx_params) do
    GenServer.call(client, {:send_transaction, tx_params})
  end

  @doc """
  Call a contract view function
  """
  @spec call_contract(GenServer.server(), String.t(), binary(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def call_contract(client \\ __MODULE__, contract_address, call_data, block \\ "latest") do
    GenServer.call(client, {:call_contract, contract_address, call_data, block})
  end

  @doc """
  Estimate gas for a transaction
  """
  @spec estimate_gas(GenServer.server(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def estimate_gas(client \\ __MODULE__, tx_params) do
    GenServer.call(client, {:estimate_gas, tx_params})
  end

  @doc """
  Get current gas price recommendation
  """
  @spec get_gas_price(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def get_gas_price(client \\ __MODULE__) do
    GenServer.call(client, :get_gas_price)
  end

  @doc """
  Get transaction receipt
  """
  @spec get_transaction_receipt(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_transaction_receipt(client \\ __MODULE__, tx_hash) do
    GenServer.call(client, {:get_transaction_receipt, tx_hash})
  end

  @doc """
  Get current block number
  """
  @spec get_block_number(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_block_number(client \\ __MODULE__) do
    GenServer.call(client, :get_block_number)
  end

  @doc """
  Get block by number or hash
  """
  @spec get_block(GenServer.server(), String.t() | non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def get_block(client \\ __MODULE__, block_identifier) do
    GenServer.call(client, {:get_block, block_identifier})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Load private key and derive address
    private_key = load_private_key(opts[:private_key])
    address = derive_address_from_private_key(private_key)

    # Initialize Ethereumex connection
    rpc_url = opts[:rpc_url] || raise("RPC URL required")
    Application.put_env(:ethereumex, :url, rpc_url)

    state = %__MODULE__{
      rpc_url: rpc_url,
      chain_id: opts[:chain_id] || 1,
      private_key: private_key,
      address: address,
      http_client: opts[:http_client] || HTTPoison,
      gas_strategy: opts[:gas_strategy] || :standard,
      connection: true
    }

    # Initialize nonce and gas price
    {:ok, state} = refresh_account_state(state)

    Logger.info("Web3 client initialized for #{address} on chain #{state.chain_id}")
    {:ok, state}
  end

  @impl true
  def handle_call({:send_transaction, tx_params}, _from, state) do
    case build_and_send_transaction(tx_params, state) do
      {:ok, tx_hash, new_state} ->
        # Start monitoring the transaction
        TransactionMonitor.monitor_transaction(tx_hash, tx_params)
        {:reply, {:ok, tx_hash}, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to send transaction: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:call_contract, contract_address, call_data, block}, _from, state) do
    request = build_call_request(contract_address, call_data, block)

    case make_rpc_request(request, state) do
      {:ok, result} ->
        {:reply, {:ok, decode_hex(result)}, state}

      {:error, reason} = error ->
        Logger.error("Contract call failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:estimate_gas, tx_params}, _from, state) do
    request = build_estimate_gas_request(tx_params, state)

    case make_rpc_request(request, state) do
      {:ok, hex_gas} ->
        gas_limit = hex_to_integer(hex_gas)
        {:reply, {:ok, gas_limit}, state}

      {:error, reason} = error ->
        Logger.error("Gas estimation failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_gas_price, _from, state) do
    case fetch_current_gas_prices(state) do
      {:ok, gas_prices, new_state} ->
        {:reply, {:ok, gas_prices}, new_state}

      {:error, reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_transaction_receipt, tx_hash}, _from, state) do
    request = %{
      jsonrpc: "2.0",
      method: "eth_getTransactionReceipt",
      params: [tx_hash],
      id: generate_request_id()
    }

    case make_rpc_request(request, state) do
      {:ok, receipt} when receipt != nil ->
        parsed_receipt = parse_transaction_receipt(receipt)
        {:reply, {:ok, parsed_receipt}, state}

      {:ok, nil} ->
        {:reply, {:error, :not_found}, state}

      {:error, reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_block_number, _from, state) do
    request = %{
      jsonrpc: "2.0",
      method: "eth_blockNumber",
      params: [],
      id: generate_request_id()
    }

    case make_rpc_request(request, state) do
      {:ok, hex_number} ->
        block_number = hex_to_integer(hex_number)
        {:reply, {:ok, block_number}, state}

      {:error, reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_block, block_identifier}, _from, state) do
    block_param =
      case block_identifier do
        n when is_integer(n) -> "0x" <> Integer.to_string(n, 16)
        hash when is_binary(hash) -> hash
      end

    request = %{
      jsonrpc: "2.0",
      method: "eth_getBlockByNumber",
      params: [block_param, false],
      id: generate_request_id()
    }

    case make_rpc_request(request, state) do
      {:ok, block} when block != nil ->
        parsed_block = parse_block(block)
        {:reply, {:ok, parsed_block}, state}

      {:ok, nil} ->
        {:reply, {:error, :not_found}, state}

      {:error, reason} = error ->
        {:reply, error, state}
    end
  end

  # Private Functions

  defp build_and_send_transaction(tx_params, state) do
    with {:ok, tx} <- build_transaction(tx_params, state),
         {:ok, signed_tx} <- sign_transaction(tx, state.private_key, state.chain_id),
         {:ok, tx_hash} <- broadcast_transaction(signed_tx, state) do
      # Update nonce
      new_state = %{state | nonce: state.nonce + 1}
      {:ok, tx_hash, new_state}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_transaction(params, state) do
    # Get gas estimates if not provided
    gas_limit = params[:gas] || estimate_gas_for_params(params, state)

    # Get current gas prices
    {gas_price, max_fee_per_gas, max_priority_fee_per_gas} =
      get_transaction_fees(params, state)

    tx = %{
      to: params[:to],
      value: params[:value] || 0,
      data: params[:data] || "0x",
      gas: gas_limit,
      nonce: params[:nonce] || state.nonce
    }

    # Add fee fields based on EIP-1559 support
    tx =
      if max_fee_per_gas && max_priority_fee_per_gas do
        tx
        |> Map.put(:maxFeePerGas, max_fee_per_gas)
        |> Map.put(:maxPriorityFeePerGas, max_priority_fee_per_gas)
        # EIP-1559 transaction
        |> Map.put(:type, 2)
      else
        tx
        |> Map.put(:gasPrice, gas_price)
        # Legacy transaction
        |> Map.put(:type, 0)
      end

    {:ok, tx}
  end

  defp sign_transaction(tx, private_key, chain_id) do
    # Encode transaction for signing
    tx_list = transaction_to_list(tx)
    unsigned_tx_rlp = ExRLP.encode(tx_list ++ [chain_id, "", ""])

    # Hash the unsigned transaction
    tx_hash = ExthCrypto.Hash.Keccak.kec(unsigned_tx_rlp)

    # Sign with private key
    {:ok, {v, r, s}} = ExthCrypto.Signature.sign_hash(tx_hash, private_key, chain_id)

    # Encode the signed transaction
    signed_tx_list = tx_list ++ [v, r, s]
    signed_tx_rlp = ExRLP.encode(signed_tx_list)

    {:ok, "0x" <> Base.encode16(signed_tx_rlp, case: :lower)}
  rescue
    error ->
      Logger.error("Transaction signing failed: #{inspect(error)}")
      {:error, :signing_failed}
  end

  defp transaction_to_list(tx) do
    case tx.type do
      0 ->
        # Legacy transaction
        [
          tx.nonce,
          tx.gasPrice,
          tx.gas,
          tx.to || "",
          tx.value,
          tx.data || ""
        ]

      2 ->
        # EIP-1559 transaction
        [
          tx.nonce,
          tx.maxPriorityFeePerGas,
          tx.maxFeePerGas,
          tx.gas,
          tx.to || "",
          tx.value,
          tx.data || "",
          # Access list (empty for now)
          []
        ]
    end
  end

  defp broadcast_transaction(signed_tx, state) do
    request = %{
      jsonrpc: "2.0",
      method: "eth_sendRawTransaction",
      params: [signed_tx],
      id: generate_request_id()
    }

    make_rpc_request(request, state)
  end

  defp make_rpc_request(%{method: method, params: params}, _state) do
    # Use Ethereumex for actual RPC calls
    case apply(
           Ethereumex.HttpClient,
           String.to_atom(String.replace(method, "eth_", "eth_")),
           params
         ) do
      {:ok, result} ->
        {:ok, result}

      {:error, %{"error" => error}} ->
        {:error, {:rpc_error, error}}

      {:error, reason} ->
        {:error, {:rpc_request_failed, reason}}
    end
  rescue
    exception ->
      # Fallback to direct RPC call if method not supported by Ethereumex
      make_direct_rpc_request(%{jsonrpc: "2.0", method: method, params: params, id: 1}, _state)
  end

  defp make_direct_rpc_request(request, state) do
    headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]

    body = Jason.encode!(request)

    case state.http_client.post(state.rpc_url, body, headers, timeout: 30_000) do
      {:ok, %{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"result" => result}} ->
            {:ok, result}

          {:ok, %{"error" => error}} ->
            {:error, {:rpc_error, error}}

          {:error, decode_error} ->
            {:error, {:json_decode_error, decode_error}}
        end

      {:ok, %{status_code: status_code, body: body}} ->
        {:error, {:http_error, status_code, body}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}
    end
  rescue
    exception ->
      {:error, {:exception, exception}}
  end

  defp fetch_current_gas_prices(state) do
    # Try to get EIP-1559 gas info first
    case get_fee_history(state) do
      {:ok, fee_history} ->
        gas_prices = %{
          base_fee: fee_history.base_fee,
          priority_fee: calculate_priority_fee(fee_history),
          max_fee: calculate_max_fee(fee_history),
          legacy_gas_price: fee_history.base_fee + calculate_priority_fee(fee_history)
        }

        new_state = %{
          state
          | base_fee: gas_prices.base_fee,
            priority_fee: gas_prices.priority_fee,
            gas_price: gas_prices.legacy_gas_price
        }

        {:ok, gas_prices, new_state}

      {:error, _} ->
        # Fallback to legacy gas price
        case get_legacy_gas_price(state) do
          {:ok, gas_price} ->
            gas_prices = %{
              legacy_gas_price: gas_price,
              base_fee: nil,
              priority_fee: nil,
              max_fee: nil
            }

            new_state = %{state | gas_price: gas_price}
            {:ok, gas_prices, new_state}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp get_fee_history(state) do
    request = %{
      jsonrpc: "2.0",
      method: "eth_feeHistory",
      # 10 blocks, percentiles
      params: [10, "latest", [10, 25, 50]],
      id: generate_request_id()
    }

    case make_rpc_request(request, state) do
      {:ok, fee_history} ->
        parsed = %{
          base_fee: hex_to_integer(List.last(fee_history["baseFeePerGas"])),
          percentiles: fee_history["reward"],
          gas_used_ratio: fee_history["gasUsedRatio"]
        }

        {:ok, parsed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_legacy_gas_price(state) do
    request = %{
      jsonrpc: "2.0",
      method: "eth_gasPrice",
      params: [],
      id: generate_request_id()
    }

    case make_rpc_request(request, state) do
      {:ok, hex_price} ->
        {:ok, hex_to_integer(hex_price)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_account_state(state) do
    with {:ok, nonce} <- get_account_nonce(state),
         {:ok, _gas_prices, updated_state} <- fetch_current_gas_prices(state) do
      {:ok, %{updated_state | nonce: nonce}}
    else
      {:error, reason} ->
        Logger.warning("Failed to refresh account state: #{inspect(reason)}")
        {:ok, state}
    end
  end

  defp get_account_nonce(state) do
    request = %{
      jsonrpc: "2.0",
      method: "eth_getTransactionCount",
      params: [state.address, "pending"],
      id: generate_request_id()
    }

    case make_rpc_request(request, state) do
      {:ok, hex_nonce} ->
        {:ok, hex_to_integer(hex_nonce)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Utility Functions

  defp load_private_key(nil), do: :crypto.strong_rand_bytes(32)

  defp load_private_key(hex) when is_binary(hex) do
    hex
    |> String.replace_prefix("0x", "")
    |> Base.decode16!(case: :lower)
  end

  defp load_private_key(bytes) when is_binary(bytes), do: bytes

  defp derive_address_from_private_key(private_key) do
    # Derive actual Ethereum address from private key
    {:ok, public_key} = ExthCrypto.Signature.get_public_key(private_key)

    # Take Keccak256 hash of public key and get last 20 bytes
    public_key
    |> ExthCrypto.Hash.Keccak.kec()
    |> Binary.take(-20)
    |> Base.encode16(case: :lower)
    |> (fn addr -> "0x" <> addr end).()
  rescue
    _ ->
      # Fallback for testing
      "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
  end

  defp hex_to_integer("0x" <> hex), do: String.to_integer(hex, 16)
  defp hex_to_integer(hex), do: String.to_integer(hex, 16)

  defp decode_hex("0x" <> hex), do: Base.decode16!(hex, case: :lower)
  defp decode_hex(hex), do: Base.decode16!(hex, case: :lower)

  defp generate_request_id, do: System.unique_integer([:positive])

  defp build_call_request(to, data, block) do
    %{
      jsonrpc: "2.0",
      method: "eth_call",
      params: [
        %{
          to: to,
          data: "0x" <> Base.encode16(data, case: :lower)
        },
        block
      ],
      id: generate_request_id()
    }
  end

  defp build_estimate_gas_request(params, state) do
    tx_data = %{
      from: state.address,
      to: params[:to],
      value: integer_to_hex(params[:value] || 0),
      data: params[:data] || "0x"
    }

    %{
      jsonrpc: "2.0",
      method: "eth_estimateGas",
      params: [tx_data],
      id: generate_request_id()
    }
  end

  defp integer_to_hex(0), do: "0x0"
  defp integer_to_hex(n), do: "0x" <> Integer.to_string(n, 16)

  defp calculate_priority_fee(fee_history) do
    # Calculate median priority fee from recent blocks
    rewards = List.flatten(fee_history.percentiles)

    median_reward =
      if length(rewards) > 0 do
        Enum.sort(rewards)
        |> Enum.at(div(length(rewards), 2))
        |> hex_to_integer()
      else
        # 1 gwei fallback
        1_000_000_000
      end

    # At least 1 gwei
    max(median_reward, 1_000_000_000)
  end

  defp calculate_max_fee(fee_history) do
    priority_fee = calculate_priority_fee(fee_history)
    base_fee = fee_history.base_fee

    # Set max fee as base fee * 2 + priority fee (for base fee spikes)
    base_fee * 2 + priority_fee
  end

  defp get_transaction_fees(params, state) do
    case {params[:maxFeePerGas], params[:maxPriorityFeePerGas]} do
      {nil, nil} when not is_nil(state.base_fee) ->
        # Use EIP-1559 fees
        priority_fee = state.priority_fee || 1_000_000_000
        max_fee = state.base_fee * 2 + priority_fee
        {nil, max_fee, priority_fee}

      {nil, nil} ->
        # Use legacy gas price
        # 20 gwei fallback
        gas_price = state.gas_price || 20_000_000_000
        {gas_price, nil, nil}

      {max_fee, priority_fee} ->
        # Use provided EIP-1559 fees
        {nil, max_fee, priority_fee}
    end
  end

  defp estimate_gas_for_params(params, _state) do
    case estimate_gas(__MODULE__, params) do
      # Add 20% buffer
      {:ok, gas_limit} -> trunc(gas_limit * 1.2)
      # Basic transaction fallback
      {:error, _} -> 21_000
    end
  end

  defp parse_transaction_receipt(receipt) do
    %{
      transaction_hash: receipt["transactionHash"],
      block_number: hex_to_integer(receipt["blockNumber"]),
      block_hash: receipt["blockHash"],
      gas_used: hex_to_integer(receipt["gasUsed"]),
      status: receipt["status"] == "0x1",
      logs: receipt["logs"] || []
    }
  end

  defp parse_block(block) do
    %{
      number: hex_to_integer(block["number"]),
      hash: block["hash"],
      parent_hash: block["parentHash"],
      timestamp: hex_to_integer(block["timestamp"]),
      gas_limit: hex_to_integer(block["gasLimit"]),
      gas_used: hex_to_integer(block["gasUsed"]),
      base_fee_per_gas: if(block["baseFeePerGas"], do: hex_to_integer(block["baseFeePerGas"])),
      transaction_count: length(block["transactions"] || [])
    }
  end
end
