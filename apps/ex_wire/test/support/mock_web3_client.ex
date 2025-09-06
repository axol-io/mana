defmodule ExWire.Layer2.MockWeb3Client do
  @moduledoc """
  Mock Web3Client for Layer 2 integration testing.
  """
  
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: ExWire.Layer2.Web3Client)
  end

  def init(_opts) do
    {:ok, %{}}
  end

  @doc """
  Mock contract call that returns predefined responses.
  """
  def call_contract(address, data) do
    # Return mock response based on method selector
    case extract_method_selector(data) do
      # latestOutputIndex() - return index 42
      "69f16eec" -> 
        {:ok, "0x" <> String.pad_leading(Integer.to_string(42, 16), 64, "0")}
      
      # getL2Output(uint256) - return mock output
      "a25ae557" ->
        {:ok, "0x" <> String.duplicate("aa", 64)}
      
      # Generic success response
      _ -> 
        {:ok, "0x" <> String.duplicate("00", 32)}
    end
  end

  @doc """
  Mock transaction sending that returns mock transaction hash.
  """
  def send_transaction(tx_params) do
    # Generate mock transaction hash based on tx params
    hash_input = :erlang.term_to_binary(tx_params)
    tx_hash = :crypto.hash(:sha256, hash_input)
    |> Base.encode16(case: :lower)
    
    {:ok, "0x" <> tx_hash}
  end

  defp extract_method_selector(data) when is_binary(data) do
    data
    |> String.replace_prefix("0x", "")
    |> String.slice(0, 8)
  end

  defp extract_method_selector(_), do: "00000000"
end