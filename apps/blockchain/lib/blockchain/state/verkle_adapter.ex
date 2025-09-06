defmodule Blockchain.State.VerkleAdapter do
  @moduledoc """
  Adapter for using Verkle Trees as the state storage backend in the blockchain.

  This module provides a seamless integration between the blockchain state
  management and the Verkle Tree implementation, allowing for gradual migration
  from Merkle Patricia Trees to Verkle Trees.

  ## Features

  - Transparent state storage using Verkle Trees
  - Backward compatibility with existing MPT-based state
  - State migration support for gradual transition
  - Optimized witness generation for stateless clients
  - EIP-6800 compliance for Ethereum state

  ## Usage

      # Create a new Verkle-based state
      state = VerkleAdapter.new_state(db)
      
      # Get an account
      {:ok, account} = VerkleAdapter.get_account(state, address)
      
      # Update an account
      new_state = VerkleAdapter.put_account(state, address, account)
      
      # Generate a witness for state access
      witness = VerkleAdapter.generate_witness(state, addresses)
  """

  alias VerkleTree
  alias VerkleTree.{Witness, Migration}
  alias MerklePatriciaTree.{DB, Trie}
  alias Blockchain.Account

  require Logger

  @type state :: %{
          verkle_tree: VerkleTree.t() | nil,
          mpt: Trie.t() | nil,
          migration: Migration.t() | nil,
          db: DB.db(),
          mode: :verkle | :mpt | :migration
        }

  @type address :: binary()
  @type storage_key :: binary()
  @type storage_value :: binary()

  # Configuration for state mode
  # Start in migration mode by default
  @default_mode :migration
  # Feature flag for conditional Verkle tree enablement
  # @verkle_enabled Application.compile_env(:blockchain, :verkle_enabled, true)

  @doc """
  Creates a new state with the specified storage backend.

  ## Options

  - `:mode` - Storage mode: `:verkle`, `:mpt`, or `:migration` (default: `:migration`)
  - `:root` - Root hash for existing state (optional)
  - `:config` - Verkle tree configuration (optional)
  """
  @spec new_state(DB.db(), keyword()) :: state()
  def new_state(db, opts \\ []) do
    mode = Keyword.get(opts, :mode, @default_mode)
    root = Keyword.get(opts, :root)
    config = Keyword.get(opts, :config, %{})

    case mode do
      :verkle ->
        %{
          verkle_tree: VerkleTree.new(db, config),
          mpt: nil,
          migration: nil,
          db: db,
          mode: :verkle
        }

      :mpt ->
        %{
          verkle_tree: nil,
          mpt: if(root, do: Trie.new(db, root), else: Trie.new(db)),
          migration: nil,
          db: db,
          mode: :mpt
        }

      :migration ->
        mpt = if(root, do: Trie.new(db, root), else: Trie.new(db))
        migration = Migration.new(mpt, db, config)

        %{
          verkle_tree: nil,
          mpt: nil,
          migration: migration,
          db: db,
          mode: :migration
        }
    end
  end

  @doc """
  Gets the state root hash.
  """
  @spec state_root(state()) :: binary()
  def state_root(%{mode: :verkle, verkle_tree: tree}) do
    tree.root_commitment
  end

  def state_root(%{mode: :mpt, mpt: trie}) do
    Trie.root_hash(trie)
  end

  def state_root(%{mode: :migration, migration: migration}) do
    Migration.get_root(migration)
  end

  @doc """
  Gets an account from the state.
  """
  @spec get_account(state(), address()) :: {:ok, Account.t()} | :not_found
  def get_account(%{mode: :verkle, verkle_tree: tree}, address) do
    account_key = account_key(address)

    case VerkleTree.get(tree, account_key) do
      {:ok, encoded} ->
        {:ok, Account.decode(encoded)}

      :not_found ->
        :not_found
    end
  end

  def get_account(%{mode: :mpt, mpt: trie}, address) do
    account_key = account_key(address)

    case Trie.get_key(trie, account_key) do
      nil -> :not_found
      encoded -> {:ok, Account.decode(encoded)}
    end
  end

  def get_account(%{mode: :migration, migration: migration}, address) do
    account_key = account_key(address)

    case Migration.get_with_migration(migration, account_key) do
      {:not_found, _} ->
        :not_found

      {{:ok, encoded}, _updated_migration} ->
        # Note: In production, we'd need to track the updated migration
        {:ok, Account.decode(encoded)}
    end
  end

  @doc """
  Puts an account into the state.
  """
  @spec put_account(state(), address(), Account.t()) :: state()
  def put_account(%{mode: :verkle, verkle_tree: tree} = state, address, account) do
    account_key = account_key(address)
    encoded = Account.encode(account)

    updated_tree = VerkleTree.put(tree, account_key, encoded)
    %{state | verkle_tree: updated_tree}
  end

  def put_account(%{mode: :mpt, mpt: trie} = state, address, account) do
    account_key = account_key(address)
    encoded = Account.encode(account)

    updated_trie = Trie.update_key(trie, account_key, encoded)
    %{state | mpt: updated_trie}
  end

  def put_account(%{mode: :migration, migration: migration} = state, address, account) do
    account_key = account_key(address)
    encoded = Account.encode(account)

    updated_migration = Migration.put(migration, account_key, encoded)
    %{state | migration: updated_migration}
  end

  @doc """
  Deletes an account from the state.
  """
  @spec delete_account(state(), address()) :: state()
  def delete_account(%{mode: :verkle, verkle_tree: tree} = state, address) do
    account_key = account_key(address)
    updated_tree = VerkleTree.remove(tree, account_key)
    %{state | verkle_tree: updated_tree}
  end

  def delete_account(%{mode: :mpt, mpt: trie} = state, address) do
    account_key = account_key(address)
    updated_trie = Trie.remove_key(trie, account_key)
    %{state | mpt: updated_trie}
  end

  def delete_account(%{mode: :migration, migration: migration} = state, address) do
    account_key = account_key(address)
    updated_migration = Migration.remove(migration, account_key)
    %{state | migration: updated_migration}
  end

  @doc """
  Gets a storage value for an account.
  """
  @spec get_storage(state(), address(), storage_key()) :: {:ok, storage_value()} | :not_found
  def get_storage(%{mode: :verkle, verkle_tree: tree}, address, storage_key) do
    full_key = storage_key(address, storage_key)

    case VerkleTree.get(tree, full_key) do
      {:ok, value} -> {:ok, value}
      :not_found -> :not_found
    end
  end

  def get_storage(%{mode: :mpt} = state, address, storage_key) do
    # For MPT, storage is in a separate trie per account
    case get_account(state, address) do
      {:ok, account} ->
        storage_trie = Trie.new(state.db, account.storage_root)

        case Trie.get_key(storage_trie, storage_key) do
          nil -> :not_found
          value -> {:ok, value}
        end

      :not_found ->
        :not_found
    end
  end

  def get_storage(%{mode: :migration, migration: migration}, address, storage_key) do
    full_key = storage_key(address, storage_key)

    case Migration.get_with_migration(migration, full_key) do
      {nil, _} -> :not_found
      {value, _} -> {:ok, value}
    end
  end

  @doc """
  Puts a storage value for an account.
  """
  @spec put_storage(state(), address(), storage_key(), storage_value()) :: state()
  def put_storage(%{mode: :verkle, verkle_tree: tree} = state, address, storage_key, value) do
    full_key = storage_key(address, storage_key)
    updated_tree = VerkleTree.put(tree, full_key, value)
    %{state | verkle_tree: updated_tree}
  end

  def put_storage(%{mode: :mpt} = state, address, storage_key, value) do
    # For MPT, we need to update the account's storage trie
    case get_account(state, address) do
      {:ok, account} ->
        storage_trie = Trie.new(state.db, account.storage_root)
        updated_storage = Trie.update_key(storage_trie, storage_key, value)
        new_storage_root = Trie.root_hash(updated_storage)

        updated_account = %{account | storage_root: new_storage_root}
        put_account(state, address, updated_account)

      :not_found ->
        # Create new account with storage
        storage_trie = Trie.new(state.db)
        updated_storage = Trie.update_key(storage_trie, storage_key, value)
        new_storage_root = Trie.root_hash(updated_storage)

        new_account = %Account{
          nonce: 0,
          balance: 0,
          storage_root: new_storage_root,
          code_hash: Account.empty_code_hash()
        }

        put_account(state, address, new_account)
    end
  end

  def put_storage(%{mode: :migration, migration: migration} = state, address, storage_key, value) do
    full_key = storage_key(address, storage_key)
    updated_migration = Migration.put(migration, full_key, value)
    %{state | migration: updated_migration}
  end

  @doc """
  Generates a witness for the given addresses.

  The witness can be used to prove the state of accounts and storage
  without requiring the full state tree.
  """
  @spec generate_witness(state(), [address()]) :: Witness.t()
  def generate_witness(%{mode: :verkle, verkle_tree: tree}, addresses) do
    keys = Enum.map(addresses, &account_key/1)
    VerkleTree.generate_witness(tree, keys)
  end

  def generate_witness(%{mode: :mpt}, _addresses) do
    # MPT witness generation would be more complex
    # For now, return a placeholder
    Logger.warning("MPT witness generation not yet implemented")
    # Return a map instead of Witness struct for MPT
    %{data: <<>>, size: 0, proof: <<>>}
  end

  def generate_witness(%{mode: :migration, migration: migration}, addresses) do
    keys = Enum.map(addresses, &account_key/1)
    Migration.generate_witness(migration, keys)
  end

  @doc """
  Verifies a witness against a state root.
  """
  @spec verify_witness(binary(), Witness.t(), [{address(), Account.t()}]) :: boolean()
  def verify_witness(root, witness, address_account_pairs) do
    kvs =
      Enum.map(address_account_pairs, fn {address, account} ->
        {account_key(address), Account.encode(account)}
      end)

    Witness.verify(witness, root, kvs)
  end

  @doc """
  Returns the migration progress if in migration mode.
  """
  @spec migration_progress(state()) :: float() | nil
  def migration_progress(%{mode: :migration, migration: migration}) do
    Migration.migration_progress(migration)
  end

  def migration_progress(_), do: nil

  @doc """
  Completes the migration and switches to pure verkle mode.
  """
  @spec complete_migration(state()) :: state()
  def complete_migration(%{mode: :migration, migration: migration} = state) do
    if Migration.migration_progress(migration) >= 100.0 do
      verkle_tree = Migration.get_verkle_tree(migration)

      %{state | mode: :verkle, verkle_tree: verkle_tree, migration: nil, mpt: nil}
    else
      Logger.warning("Migration not complete: #{Migration.migration_progress(migration)}%")
      state
    end
  end

  def complete_migration(state), do: state

  # Private helper functions

  defp account_key(address) do
    # EIP-6800: Account key is hash(address || 0)
    ExthCrypto.Hash.Keccak.kec(<<address::binary, 0::8>>)
  end

  defp storage_key(address, key) do
    # EIP-6800: Storage key is hash(address || hash(key))
    key_hash = ExthCrypto.Hash.Keccak.kec(key)
    ExthCrypto.Hash.Keccak.kec(<<address::binary, key_hash::binary>>)
  end
end
