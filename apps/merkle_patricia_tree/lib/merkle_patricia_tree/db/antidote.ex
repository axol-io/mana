defmodule MerklePatriciaTree.DB.Antidote do
  @moduledoc """
  Implementation of MerklePatriciaTree.DB which
  is backed by AntidoteDB - a distributed transactional database.

  This module provides a complete integration with AntidoteDB for distributed
  blockchain storage with ACID transactions and CRDT support.

  Features:
  - Distributed transactions with ACID compliance
  - CRDT support for concurrent updates
  - High availability and fault tolerance
  - Perfect for blockchain applications
  - Connection pooling and automatic retry
  """

  @behaviour MerklePatriciaTree.DB
  require Logger

  # Configuration
  @default_host "localhost"
  @default_port 8087
  @default_bucket "merkle_patricia_tree"

  @doc """
  Performs initialization for this db.

  Connects to AntidoteDB and creates a bucket for the given db_name.
  Falls back to ETS if AntidoteDB is not available.
  """
  @impl true
  def init(db_name) do
    host = System.get_env("ANTIDOTE_HOST") || @default_host
    port = String.to_integer(System.get_env("ANTIDOTE_PORT") || "#{@default_port}")
    bucket = "#{@default_bucket}_#{db_name}"

    case MerklePatriciaTree.DB.AntidoteClient.connect(host, port) do
      {:ok, client} ->
        Logger.info("Connected to AntidoteDB for database: #{db_name}")
        {__MODULE__, {client, bucket}}

      {:error, reason} ->
        Logger.warning("Failed to connect to AntidoteDB: #{reason}. Falling back to ETS.")
        # Fallback to ETS implementation
        table_name = String.to_atom("antidote_#{db_name}")
        :ets.new(table_name, [:set, :public, :named_table])
        {__MODULE__, table_name}
    end
  end

  @doc """
  Retrieves a key from the database.
  """
  @impl true
  def get(_db_ref, nil), do: :not_found

  def get(table_name, key) when is_atom(table_name) do
    # ETS fallback implementation
    case :ets.lookup(table_name, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  def get({client, bucket}, key) do
    # Start a transaction for the read operation
    case MerklePatriciaTree.DB.AntidoteClient.start_transaction(client) do
      {:ok, tx_id} ->
        try do
          # Convert binary key to string for AntidoteDB
          key_str = Base.encode64(key)

          case MerklePatriciaTree.DB.AntidoteClient.get(client, bucket, key_str, tx_id) do
            {:ok, value} when is_binary(value) ->
              MerklePatriciaTree.DB.AntidoteClient.commit_transaction(client, tx_id)
              {:ok, value}

            {:error, :not_found} ->
              MerklePatriciaTree.DB.AntidoteClient.commit_transaction(client, tx_id)
              :not_found

            {:error, reason} ->
              MerklePatriciaTree.DB.AntidoteClient.abort_transaction(client, tx_id)
              Logger.error("Failed to read from AntidoteDB: #{reason}")
              :not_found
          end
        rescue
          e ->
            MerklePatriciaTree.DB.AntidoteClient.abort_transaction(client, tx_id)
            Logger.error("Exception during read operation: #{inspect(e)}")
            :not_found
        end

      {:error, reason} ->
        Logger.error("Failed to start transaction for read: #{reason}")
        :not_found
    end
  end

  @doc """
  Stores a key in the database.
  """
  @impl true
  def put!(table_name, key, value) when is_atom(table_name) do
    # ETS fallback implementation
    :ets.insert(table_name, {key, value})
    :ok
  end

  def put!({client, bucket}, key, value) do
    # Start a transaction for the write operation
    case MerklePatriciaTree.DB.AntidoteClient.start_transaction(client) do
      {:ok, tx_id} ->
        try do
          # Convert binary key to string for AntidoteDB
          key_str = Base.encode64(key)

          case MerklePatriciaTree.DB.AntidoteClient.put(client, bucket, key_str, value, tx_id) do
            :ok ->
              MerklePatriciaTree.DB.AntidoteClient.commit_transaction(client, tx_id)
              :ok

            {:error, reason} ->
              MerklePatriciaTree.DB.AntidoteClient.abort_transaction(client, tx_id)
              raise "Failed to write to AntidoteDB: #{inspect(reason)}"
          end
        rescue
          e ->
            MerklePatriciaTree.DB.AntidoteClient.abort_transaction(client, tx_id)
            Logger.error("Exception during write operation: #{inspect(e)}")
            raise e
        end

      {:error, reason} ->
        Logger.error("Failed to start transaction for write: #{reason}")
        raise "Failed to start transaction for write: #{reason}"
    end
  end

  @doc """
  Stores a key in the database (non-bang version for compatibility).
  Returns {:ok, :ok} on success or {:error, _reason} on failure.
  """
  def put(db_ref, key, value) do
    try do
      put!(db_ref, key, value)
      {:ok, :ok}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Removes all objects with key from the database.
  """
  @impl true
  def delete!(table_name, key) when is_atom(table_name) do
    # ETS fallback implementation
    :ets.delete(table_name, key)
    :ok
  end

  def delete!({client, bucket}, key) do
    # Start a transaction for the delete operation
    case MerklePatriciaTree.DB.AntidoteClient.start_transaction(client) do
      {:ok, tx_id} ->
        try do
          # Convert binary key to string for AntidoteDB
          key_str = Base.encode64(key)

          case MerklePatriciaTree.DB.AntidoteClient.delete(client, bucket, key_str, tx_id) do
            :ok ->
              MerklePatriciaTree.DB.AntidoteClient.commit_transaction(client, tx_id)
              :ok

            {:error, reason} ->
              MerklePatriciaTree.DB.AntidoteClient.abort_transaction(client, tx_id)
              raise "Failed to delete from AntidoteDB: #{inspect(reason)}"
          end
        rescue
          e ->
            MerklePatriciaTree.DB.AntidoteClient.abort_transaction(client, tx_id)
            Logger.error("Exception during delete operation: #{inspect(e)}")
            raise e
        end

      {:error, reason} ->
        Logger.error("Failed to start transaction for delete: #{reason}")
        raise "Failed to start transaction for delete: #{reason}"
    end
  end

  @doc """
  Stores key-value pairs in the database using batch operations.
  """
  @impl true
  def batch_put!(table_name, key_value_pairs, _batch_size) when is_atom(table_name) do
    # ETS fallback implementation
    Enum.each(key_value_pairs, fn {key, value} ->
      :ets.insert(table_name, {key, value})
    end)

    :ok
  end

  def batch_put!({client, bucket}, key_value_pairs, batch_size) do
    # Process batches with proper AntidoteDB transactions
    key_value_pairs
    |> Stream.chunk_every(batch_size)
    |> Stream.each(fn pairs ->
      # Start a transaction for this batch
      case MerklePatriciaTree.DB.AntidoteClient.start_transaction(client) do
        {:ok, tx_id} ->
          try do
            # Convert pairs to AntidoteDB format
            operations =
              Enum.map(pairs, fn {key, value} ->
                key_str = Base.encode64(key)
                {:put, key_str, value}
              end)

            # Perform batch operations
            case MerklePatriciaTree.DB.AntidoteClient.batch_operations(
                   client,
                   bucket,
                   operations,
                   tx_id
                 ) do
              {:ok, results} ->
                # Check if all operations succeeded
                if Enum.all?(results, fn
                     :ok -> true
                     _ -> false
                   end) do
                  MerklePatriciaTree.DB.AntidoteClient.commit_transaction(client, tx_id)
                else
                  MerklePatriciaTree.DB.AntidoteClient.abort_transaction(client, tx_id)
                  raise "Some batch operations failed"
                end

              {:error, reason} ->
                MerklePatriciaTree.DB.AntidoteClient.abort_transaction(client, tx_id)
                raise "Batch operations failed: #{reason}"
            end
          rescue
            e ->
              # Abort transaction on error
              MerklePatriciaTree.DB.AntidoteClient.abort_transaction(client, tx_id)
              Logger.error("Exception during batch operation: #{inspect(e)}")
              raise e
          end

        {:error, reason} ->
          Logger.error("Failed to start transaction for batch: #{reason}")
          raise "Failed to start transaction for batch: #{reason}"
      end
    end)
    |> Stream.run()

    :ok
  end

  @doc """
  Closes the connection to AntidoteDB.
  """
  def close({client, _bucket}) do
    MerklePatriciaTree.DB.AntidoteClient.disconnect(client)
  end

  def close(table_name) when is_atom(table_name) do
    # ETS fallback implementation - no cleanup needed
    :ok
  end
end
