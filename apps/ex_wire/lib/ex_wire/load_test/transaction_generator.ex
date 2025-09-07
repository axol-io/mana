defmodule ExWire.LoadTest.TransactionGenerator do
  @moduledoc """
  Generates realistic Ethereum transaction workloads for load testing.

  Supports various transaction types matching mainnet patterns:
  - Simple ETH transfers
  - ERC20 token transfers  
  - Smart contract interactions
  - DeFi operations (Uniswap, Compound, Aave)
  - NFT minting and transfers
  - Complex multi-call transactions
  """

  alias Blockchain.Transaction

  @eth_decimals 18
  # 30 Gwei
  @typical_gas_price 30_000_000_000
  @erc20_transfer_gas 65_000
  @simple_transfer_gas 21_000
  @contract_call_gas 100_000
  # @complex_operation_gas 300_000 # TODO: Unused attribute

  # Common mainnet contract addresses for realistic testing
  @contracts %{
    usdt: <<0xDAC17F958D2EE523A2206206994597C13D831EC7::160>>,
    usdc: <<0xA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48::160>>,
    dai: <<0x6B175474E89094C44DA98B954EEDEAC495271D0F::160>>,
    uniswap_v3_router: <<0xE592427A0AECE92DE3EDEE1F18E0157C05861564::160>>,
    opensea: <<0x7BE8076F4EA4A4AD08075C2508E481D6C946D12B::160>>
  }

  @doc """
  Generate simple ETH transfer transactions.
  """
  def generate_simple_transfers(opts \\ []) do
    count = Keyword.get(opts, :count, 100)
    accounts = Keyword.get(opts, :accounts, generate_accounts(100))

    Enum.map(1..count, fn i ->
      from = Enum.random(accounts)
      to = Enum.random(accounts -- [from])

      %Transaction{
        nonce: calculate_nonce(from, i),
        gas_price: vary_gas_price(@typical_gas_price),
        gas_limit: @simple_transfer_gas,
        to: to,
        value: random_eth_amount(),
        data: <<>>,
        v: 27,
        r: :crypto.strong_rand_bytes(32),
        s: :crypto.strong_rand_bytes(32)
      }
      |> sign_transaction(from)
    end)
  end

  @doc """
  Generate ERC20 token transfer transactions.
  """
  def generate_token_transfers(opts \\ []) do
    count = Keyword.get(opts, :count, 100)
    accounts = Keyword.get(opts, :accounts, generate_accounts(100))
    token = Keyword.get(opts, :token, :usdt)

    token_address = @contracts[token] || @contracts[:usdt]

    Enum.map(1..count, fn i ->
      from = Enum.random(accounts)
      to = Enum.random(accounts -- [from])
      amount = random_token_amount(token)

      # ERC20 transfer function signature: transfer(address,uint256)
      data = encode_erc20_transfer(to, amount)

      %Transaction{
        nonce: calculate_nonce(from, i),
        gas_price: vary_gas_price(@typical_gas_price),
        gas_limit: @erc20_transfer_gas,
        to: token_address,
        value: 0,
        data: data,
        v: 27,
        r: :crypto.strong_rand_bytes(32),
        s: :crypto.strong_rand_bytes(32)
      }
      |> sign_transaction(from)
    end)
  end

  @doc """
  Generate smart contract interaction transactions.
  """
  def generate_contract_calls(opts \\ []) do
    count = Keyword.get(opts, :count, 100)
    accounts = Keyword.get(opts, :accounts, generate_accounts(100))

    Enum.map(1..count, fn i ->
      from = Enum.random(accounts)
      contract_type = Enum.random([:defi, :nft, :dao, :game])

      {to, data, gas_limit} = generate_contract_call_data(contract_type, from)

      %Transaction{
        nonce: calculate_nonce(from, i),
        gas_price: vary_gas_price(@typical_gas_price),
        gas_limit: gas_limit,
        to: to,
        value: if(contract_type == :nft, do: random_eth_amount(), else: 0),
        data: data,
        v: 27,
        r: :crypto.strong_rand_bytes(32),
        s: :crypto.strong_rand_bytes(32)
      }
      |> sign_transaction(from)
    end)
  end

  @doc """
  Generate complex DeFi operations (swaps, lending, yield farming).
  """
  def generate_complex_operations(opts \\ []) do
    count = Keyword.get(opts, :count, 50)
    accounts = Keyword.get(opts, :accounts, generate_accounts(100))

    Enum.map(1..count, fn i ->
      from = Enum.random(accounts)
      operation = Enum.random([:uniswap_swap, :compound_lend, :aave_borrow, :curve_pool])

      {to, data, value, gas_limit} = generate_defi_operation(operation, from)

      %Transaction{
        nonce: calculate_nonce(from, i),
        # Higher priority for DeFi
        gas_price: vary_gas_price(@typical_gas_price * 1.5),
        gas_limit: gas_limit,
        to: to,
        value: value,
        data: data,
        v: 27,
        r: :crypto.strong_rand_bytes(32),
        s: :crypto.strong_rand_bytes(32)
      }
      |> sign_transaction(from)
    end)
  end

  @doc """
  Generate failing transactions for error handling tests.
  """
  def generate_failing_transactions(opts \\ []) do
    count = Keyword.get(opts, :count, 50)
    accounts = Keyword.get(opts, :accounts, generate_accounts(100))

    failure_types = [
      :insufficient_gas,
      :insufficient_balance,
      :invalid_nonce,
      :contract_revert,
      :invalid_signature
    ]

    Enum.map(1..count, fn i ->
      from = Enum.random(accounts)
      failure_type = Enum.random(failure_types)

      create_failing_transaction(failure_type, from, i)
    end)
  end

  @doc """
  Generate transactions with specific gas price patterns.
  """
  def generate_gas_price_scenarios(opts \\ []) do
    count = Keyword.get(opts, :count, 100)
    accounts = Keyword.get(opts, :accounts, generate_accounts(100))

    patterns = [
      {:zero_gas, 0},
      # 1 Gwei
      {:low_gas, 1_000_000_000},
      # 30 Gwei
      {:normal_gas, 30_000_000_000},
      # 200 Gwei
      {:high_gas, 200_000_000_000},
      # 500 Gwei
      {:max_gas, 500_000_000_000}
    ]

    Enum.flat_map(patterns, fn {_type, gas_price} ->
      Enum.map(1..(count / length(patterns)), fn i ->
        from = Enum.random(accounts)
        to = Enum.random(accounts -- [from])

        %Transaction{
          nonce: calculate_nonce(from, i),
          gas_price: gas_price,
          gas_limit: @simple_transfer_gas,
          to: to,
          value: random_eth_amount(),
          data: <<>>,
          v: 27,
          r: :crypto.strong_rand_bytes(32),
          s: :crypto.strong_rand_bytes(32)
        }
        |> sign_transaction(from)
      end)
    end)
  end

  @doc """
  Generate burst pattern transactions (simulating NFT drops, DEX launches).
  """
  def generate_burst_transactions(opts \\ []) do
    burst_size = Keyword.get(opts, :burst_size, 1000)
    accounts = Keyword.get(opts, :accounts, generate_accounts(100))
    target = Keyword.get(opts, :target, @contracts[:opensea])

    # All transactions target same contract (NFT drop scenario)
    Enum.map(1..burst_size, fn i ->
      from = Enum.random(accounts)

      %Transaction{
        nonce: calculate_nonce(from, i),
        # High priority for drops
        gas_price: vary_gas_price(@typical_gas_price * 3),
        gas_limit: 150_000,
        to: target,
        value: :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned(),
        data: encode_nft_mint(),
        v: 27,
        r: :crypto.strong_rand_bytes(32),
        s: :crypto.strong_rand_bytes(32)
      }
      |> sign_transaction(from)
    end)
  end

  @doc """
  Generate transactions that stress state access patterns.
  """
  def generate_state_stress_transactions(opts \\ []) do
    count = Keyword.get(opts, :count, 100)
    accounts = Keyword.get(opts, :accounts, generate_accounts(100))

    # Create transactions that access many storage slots
    Enum.map(1..count, fn i ->
      from = Enum.random(accounts)

      # Multi-contract interaction
      data =
        encode_multicall(
          Enum.map(1..10, fn _ ->
            {Enum.random(Map.values(@contracts)), random_contract_call()}
          end)
        )

      %Transaction{
        nonce: calculate_nonce(from, i),
        gas_price: vary_gas_price(@typical_gas_price),
        # High gas for multi-call
        gas_limit: 1_000_000,
        # Multicall contract
        to: <<0x5BA1E12693DC8F9C48AAD8770482F4739BEED696::160>>,
        value: 0,
        data: data,
        v: 27,
        r: :crypto.strong_rand_bytes(32),
        s: :crypto.strong_rand_bytes(32)
      }
      |> sign_transaction(from)
    end)
  end

  # Private helper functions

  defp generate_accounts(count) do
    Enum.map(1..count, fn _ ->
      :crypto.strong_rand_bytes(20)
    end)
  end

  defp calculate_nonce(account, index) do
    # Simulate realistic nonce progression
    base_nonce = :erlang.phash2(account, 1000)
    base_nonce + div(index, 10)
  end

  defp vary_gas_price(base_price) do
    # Add 10-20% variation to gas price
    variation = :rand.uniform(20) + 90
    div(base_price * variation, 100)
  end

  defp random_eth_amount do
    # Random amount between 0.001 and 10 ETH
    # 0.001 ETH
    min = 1_000_000_000_000_000
    # 10 ETH
    max = 10_000_000_000_000_000_000
    min + :rand.uniform(max - min)
  end

  defp random_token_amount(token) do
    decimals =
      case token do
        :usdc -> 6
        :usdt -> 6
        _ -> 18
      end

    # Random amount between 1 and 10000 tokens
    base = :math.pow(10, decimals) |> round()
    base + :rand.uniform(10000 * base)
  end

  defp encode_erc20_transfer(to, amount) do
    # transfer(address,uint256) = 0xa9059cbb
    function_selector = <<0xA9059CBB::32>>
    encoded_to = pad_address(to)
    encoded_amount = pad_uint256(amount)

    function_selector <> encoded_to <> encoded_amount
  end

  defp generate_contract_call_data(:defi, _from) do
    contract = @contracts[:uniswap_v3_router]
    # Simplified swap encoding
    data = <<0x414BF389::32>> <> :crypto.strong_rand_bytes(256)
    {contract, data, 200_000}
  end

  defp generate_contract_call_data(:nft, _from) do
    contract = @contracts[:opensea]
    data = encode_nft_mint()
    {contract, data, 150_000}
  end

  defp generate_contract_call_data(:dao, _from) do
    # Generic DAO voting
    contract = :crypto.strong_rand_bytes(20)
    data = <<0x15373E3D::32>> <> :crypto.strong_rand_bytes(64)
    {contract, data, 100_000}
  end

  defp generate_contract_call_data(:game, _from) do
    # Gaming contract interaction
    contract = :crypto.strong_rand_bytes(20)
    data = :crypto.strong_rand_bytes(100)
    {contract, data, 150_000}
  end

  defp generate_defi_operation(:uniswap_swap, _from) do
    router = @contracts[:uniswap_v3_router]
    # exactInputSingle encoding
    data = <<0x414BF389::32>> <> encode_swap_params()
    value = random_eth_amount()
    {router, data, value, 250_000}
  end

  defp generate_defi_operation(:compound_lend, _from) do
    # Simplified Compound lending
    ctoken = :crypto.strong_rand_bytes(20)
    data = <<0xA0712D68::32>> <> pad_uint256(random_eth_amount())
    {ctoken, data, 0, 200_000}
  end

  defp generate_defi_operation(:aave_borrow, _from) do
    # Simplified Aave borrowing
    pool = :crypto.strong_rand_bytes(20)
    data = <<0xA415BCAD::32>> <> :crypto.strong_rand_bytes(256)
    {pool, data, 0, 300_000}
  end

  defp generate_defi_operation(:curve_pool, _from) do
    # Curve pool exchange
    pool = :crypto.strong_rand_bytes(20)
    data = <<0x3DF02124::32>> <> :crypto.strong_rand_bytes(128)
    value = random_eth_amount()
    {pool, data, value, 400_000}
  end

  defp create_failing_transaction(:insufficient_gas, from, i) do
    %Transaction{
      nonce: calculate_nonce(from, i),
      gas_price: @typical_gas_price,
      # Too low
      gas_limit: 100,
      to: :crypto.strong_rand_bytes(20),
      value: random_eth_amount(),
      data: <<>>,
      v: 27,
      r: :crypto.strong_rand_bytes(32),
      s: :crypto.strong_rand_bytes(32)
    }
  end

  defp create_failing_transaction(:insufficient_balance, from, i) do
    %Transaction{
      nonce: calculate_nonce(from, i),
      gas_price: @typical_gas_price,
      gas_limit: @simple_transfer_gas,
      to: :crypto.strong_rand_bytes(20),
      # Huge amount
      value: 999_999_999_999_999_999_999_999,
      data: <<>>,
      v: 27,
      r: :crypto.strong_rand_bytes(32),
      s: :crypto.strong_rand_bytes(32)
    }
  end

  defp create_failing_transaction(:invalid_nonce, from, _i) do
    %Transaction{
      # Wrong nonce
      nonce: 999_999,
      gas_price: @typical_gas_price,
      gas_limit: @simple_transfer_gas,
      to: :crypto.strong_rand_bytes(20),
      value: random_eth_amount(),
      data: <<>>,
      v: 27,
      r: :crypto.strong_rand_bytes(32),
      s: :crypto.strong_rand_bytes(32)
    }
  end

  defp create_failing_transaction(:contract_revert, from, i) do
    %Transaction{
      nonce: calculate_nonce(from, i),
      gas_price: @typical_gas_price,
      gas_limit: 100_000,
      to: @contracts[:usdt],
      value: 0,
      # Invalid function
      data: <<0xDEADBEEF::32>>,
      v: 27,
      r: :crypto.strong_rand_bytes(32),
      s: :crypto.strong_rand_bytes(32)
    }
  end

  defp create_failing_transaction(:invalid_signature, from, i) do
    %Transaction{
      nonce: calculate_nonce(from, i),
      gas_price: @typical_gas_price,
      gas_limit: @simple_transfer_gas,
      to: :crypto.strong_rand_bytes(20),
      value: random_eth_amount(),
      data: <<>>,
      # Wrong chain ID
      v: 35,
      # Invalid r
      r: <<0::256>>,
      # Invalid s
      s: <<0::256>>
    }
  end

  defp encode_nft_mint do
    # Simplified NFT mint encoding
    <<0x1249C58B::32>> <> :crypto.strong_rand_bytes(32)
  end

  defp encode_multicall(calls) do
    # Multicall2 aggregate encoding
    selector = <<0x252DBA42::32>>

    encoded_calls =
      Enum.map(calls, fn {target, calldata} ->
        pad_address(target) <> pad_bytes(calldata)
      end)
      |> Enum.join()

    selector <> encoded_calls
  end

  defp encode_swap_params do
    # Simplified Uniswap V3 swap params
    :crypto.strong_rand_bytes(256)
  end

  defp random_contract_call do
    # Random contract call data
    :crypto.strong_rand_bytes(:rand.uniform(200) + 50)
  end

  defp pad_address(address) when byte_size(address) == 20 do
    <<0::96>> <> address
  end

  defp pad_uint256(value) when is_integer(value) do
    <<value::256>>
  end

  defp pad_bytes(data) do
    len = byte_size(data)
    padding = 32 - rem(len, 32)
    data <> <<0::padding*8>>
  end

  defp sign_transaction(tx, _from) do
    # Simplified signing - in real implementation would use proper ECDSA
    tx
  end
end
