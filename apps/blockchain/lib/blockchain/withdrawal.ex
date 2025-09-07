defmodule Blockchain.Withdrawal do
  @moduledoc """
  EIP-4895 Beacon Chain Withdrawal implementation.

  Withdrawals are push-based balance increases from the consensus layer
  to the execution layer. They are processed after user transactions in
  each block.
  """

  alias Blockchain.Account.Repo
  alias MerklePatriciaTree.Trie

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          validator_index: non_neg_integer(),
          address: EVM.address(),
          # Amount in Gwei
          amount: non_neg_integer()
        }

  defstruct [
    :index,
    :validator_index,
    :address,
    :amount
  ]

  @doc """
  Serialize a withdrawal for RLP encoding.

  Format: [index, validator_index, address, amount]
  """
  @spec serialize(t()) :: list()
  def serialize(%__MODULE__{} = withdrawal) do
    [
      withdrawal.index |> BitHelper.encode_unsigned(),
      withdrawal.validator_index |> BitHelper.encode_unsigned(),
      withdrawal.address,
      withdrawal.amount |> BitHelper.encode_unsigned()
    ]
  end

  @doc """
  Deserialize a withdrawal from RLP-decoded data.
  """
  @spec deserialize(list()) :: {:ok, t()} | {:error, term()}
  def deserialize([index, validator_index, address, amount])
      when byte_size(address) == 20 do
    {:ok,
     %__MODULE__{
       index: :binary.decode_unsigned(index),
       validator_index: :binary.decode_unsigned(validator_index),
       address: address,
       amount: :binary.decode_unsigned(amount)
     }}
  end

  def deserialize(_), do: {:error, :invalid_withdrawal}

  @doc """
  Process a single withdrawal by increasing the recipient's balance.

  The balance change is unconditional and must not fail.
  Amount is converted from Gwei to Wei (multiply by 10^9).
  """
  @spec process_withdrawal(t(), Repo.t()) :: Repo.t()
  def process_withdrawal(%__MODULE__{} = withdrawal, account_repo) do
    wei_amount = gwei_to_wei(withdrawal.amount)

    # Get current account or create if doesn't exist
    {repo, account} = get_or_create_account(account_repo, withdrawal.address)

    # Increase balance unconditionally
    updated_account = %{account | balance: account.balance + wei_amount}

    # Save updated account
    repo.put_account(repo, withdrawal.address, updated_account)
  end

  @doc """
  Process all withdrawals in a block.

  Withdrawals are processed in order after all user transactions.
  """
  @spec process_withdrawals(list(t()), Repo.t()) :: Repo.t()
  def process_withdrawals(withdrawals, account_repo) do
    Enum.reduce(withdrawals, account_repo, fn withdrawal, repo ->
      process_withdrawal(withdrawal, repo)
    end)
  end

  @doc """
  Calculate the withdrawals root for a block header.

  The withdrawals root is the root hash of a trie containing
  RLP-encoded withdrawals indexed by their position.
  """
  @spec calculate_withdrawals_root(list(t()), Trie.t()) :: binary()
  def calculate_withdrawals_root([], _trie), do: Trie.empty_trie_root_hash()

  def calculate_withdrawals_root(withdrawals, trie) do
    withdrawals
    |> Enum.with_index()
    |> Enum.reduce(trie, fn {withdrawal, index}, acc_trie ->
      key = index |> :binary.encode_unsigned() |> ExRLP.encode()
      value = withdrawal |> serialize() |> ExRLP.encode()

      Trie.update_key(acc_trie, key, value)
    end)
    |> Trie.root_hash()
  end

  @doc """
  Validate a withdrawal.

  Checks:
  - Index must be monotonically increasing (checked at block level)
  - Address must be valid 20-byte Ethereum address
  - Amount must be positive
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = withdrawal) do
    cond do
      byte_size(withdrawal.address) != 20 ->
        {:error, :invalid_withdrawal_address}

      withdrawal.amount <= 0 ->
        {:error, :invalid_withdrawal_amount}

      true ->
        :ok
    end
  end

  @doc """
  Validate a list of withdrawals for a block.

  Ensures indices are monotonically increasing and all withdrawals are valid.
  """
  @spec validate_withdrawals(list(t())) :: :ok | {:error, term()}
  def validate_withdrawals([]), do: :ok

  def validate_withdrawals(withdrawals) do
    # Check each withdrawal is valid
    case Enum.find(withdrawals, fn w -> validate(w) != :ok end) do
      nil ->
        # Check indices are monotonically increasing
        if monotonic_indices?(withdrawals) do
          :ok
        else
          {:error, :withdrawal_indices_not_monotonic}
        end

      invalid_withdrawal ->
        validate(invalid_withdrawal)
    end
  end

  @doc """
  Convert Gwei amount to Wei.
  1 Gwei = 10^9 Wei
  """
  @spec gwei_to_wei(non_neg_integer()) :: non_neg_integer()
  def gwei_to_wei(gwei), do: gwei * 1_000_000_000

  @doc """
  Convert Wei amount to Gwei.
  """
  @spec wei_to_gwei(non_neg_integer()) :: non_neg_integer()
  def wei_to_gwei(wei), do: div(wei, 1_000_000_000)

  # Private functions

  defp get_or_create_account(account_repo, address) do
    case account_repo.account(account_repo, address) do
      {repo, nil} ->
        # Create new account with zero balance
        new_account = %Blockchain.Account{
          nonce: 0,
          balance: 0,
          storage_root: Trie.empty_trie_root_hash(),
          code_hash: ExthCrypto.Hash.Keccak.kec(<<>>)
        }

        {repo, new_account}

      {repo, account} ->
        {repo, account}
    end
  end

  defp monotonic_indices?(withdrawals) do
    withdrawals
    |> Enum.map(& &1.index)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> a < b end)
  end
end
