defmodule MerklePatriciaTree.Test.AntiodoteMock do
  @moduledoc """
  Mock implementation of AntidoteDB for testing.

  Provides in-memory storage that mimics AntidoteDB behavior without
  requiring actual network connections or distributed infrastructure.
  This significantly speeds up tests and removes external dependencies.
  """

  @behaviour MerklePatriciaTree.DB

  use Agent

  @doc """
  Starts the mock storage agent.
  """
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc """
  Initializes the mock database.
  Returns a reference that includes the agent name.
  """
  @impl true
  def init(db_name) do
    # Create a unique agent for this database
    agent_name = :"#{__MODULE__}_#{db_name}"

    case Agent.start_link(fn -> %{} end, name: agent_name) do
      {:ok, _pid} ->
        {__MODULE__, agent_name}

      {:error, {:already_started, _pid}} ->
        # If already started, just return the reference
        {__MODULE__, agent_name}

      error ->
        error
    end
  end

  @doc """
  Gets a value from the mock storage.
  """
  @impl true
  def get({__MODULE__, agent_name}, key) do
    case Agent.get(agent_name, &Map.get(&1, key)) do
      nil -> :not_found
      value -> {:ok, value}
    end
  rescue
    _ -> :not_found
  end

  @doc """
  Stores a value in the mock storage.
  """
  @impl true
  def put!({__MODULE__, agent_name}, key, value) do
    Agent.update(agent_name, &Map.put(&1, key, value))
    :ok
  rescue
    _ -> raise "Failed to put value in mock storage"
  end

  @doc """
  Deletes a value from the mock storage.
  """
  @impl true
  def delete!({__MODULE__, agent_name}, key) do
    Agent.update(agent_name, &Map.delete(&1, key))
    :ok
  rescue
    _ -> raise "Failed to delete value from mock storage"
  end

  @doc """
  Clears all data from the mock storage.
  Useful for test cleanup.
  """
  def clear({__MODULE__, agent_name}) do
    Agent.update(agent_name, fn _ -> %{} end)
    :ok
  end

  @doc """
  Gets all keys from the mock storage.
  Useful for debugging tests.
  """
  def all_keys({__MODULE__, agent_name}) do
    Agent.get(agent_name, &Map.keys(&1))
  end

  @doc """
  Gets the entire storage map.
  Useful for test assertions.
  """
  def get_all({__MODULE__, agent_name}) do
    Agent.get(agent_name, & &1)
  end

  @doc """
  Stops the mock storage agent.
  """
  def stop({__MODULE__, agent_name}) do
    Agent.stop(agent_name)
  rescue
    _ -> :ok
  end
end

defmodule MerklePatriciaTree.Test.AntidoteClientMock do
  @moduledoc """
  Mock implementation of the AntidoteClient for testing.

  Provides transaction-like behavior without actual distributed transactions.
  """

  @doc """
  Mock connection - always succeeds.
  """
  def connect(_host, _port) do
    {:ok, :mock_client}
  end

  @doc """
  Mock transaction start - returns a simple transaction ID.
  """
  def start_transaction(_client) do
    {:ok, :erlang.unique_integer([:positive])}
  end

  @doc """
  Mock transaction commit - always succeeds.
  """
  def commit_transaction(_client, _tx_id) do
    :ok
  end

  @doc """
  Mock transaction abort - always succeeds.
  """
  def abort_transaction(_client, _tx_id) do
    :ok
  end

  @doc """
  Mock get operation - delegates to the mock storage.
  """
  def get(_client, bucket, key, _tx_id \\ nil) do
    agent_name = :"#{MerklePatriciaTree.Test.AntiodoteMock}_#{bucket}"

    case Process.whereis(agent_name) do
      nil ->
        {:error, :not_found}

      _pid ->
        case Agent.get(agent_name, &Map.get(&1, key)) do
          nil -> {:error, :not_found}
          value -> {:ok, value}
        end
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc """
  Mock put operation - delegates to the mock storage.
  """
  def put(_client, bucket, key, value, _tx_id \\ nil) do
    agent_name = :"#{MerklePatriciaTree.Test.AntiodoteMock}_#{bucket}"

    # Ensure the agent exists
    case Process.whereis(agent_name) do
      nil ->
        Agent.start_link(fn -> %{} end, name: agent_name)

      _pid ->
        :ok
    end

    Agent.update(agent_name, &Map.put(&1, key, value))
    :ok
  rescue
    _ -> {:error, :write_failed}
  end

  @doc """
  Mock put! operation - delegates to put and raises on error.
  """
  def put!(client, bucket, key, value, tx_id \\ nil) do
    case put(client, bucket, key, value, tx_id) do
      :ok -> :ok
      {:error, reason} -> raise "Failed to put: #{reason}"
    end
  end

  @doc """
  Mock list_keys operation - returns all keys in the bucket.
  """
  def list_keys(_client, bucket) do
    agent_name = :"#{MerklePatriciaTree.Test.AntiodoteMock}_#{bucket}"

    case Process.whereis(agent_name) do
      nil ->
        {:ok, []}

      _pid ->
        keys = Agent.get(agent_name, &Map.keys(&1))
        {:ok, keys}
    end
  rescue
    _ -> {:ok, []}
  end

  @doc """
  Mock start_link - creates the mock client process.
  """
  def start_link(_host, _port) do
    # Return a mock process reference
    {:ok, self()}
  end
end

defmodule MerklePatriciaTree.Test.AntidoteConnectionPoolMock do
  @moduledoc """
  Mock implementation of the AntidoteConnectionPool for testing.

  Simulates connection pooling without actual network connections.
  """

  use GenServer

  @doc """
  Starts the mock connection pool.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Mock pool start - always succeeds.
  """
  def start_pool(_pool_name, _opts) do
    {:ok, self()}
  end

  @doc """
  Mock pool stop - always succeeds.
  """
  def stop_pool(_pool_name) do
    :ok
  end

  @doc """
  Mock read operation - returns mock data.
  """
  def read(key, _opts \\ []) do
    # Return mock data based on key
    {:ok, "mock_value_for_#{key}"}
  end

  @doc """
  Mock write operation - always succeeds.
  """
  def write(_key, _value, _opts \\ []) do
    :ok
  end

  @doc """
  Mock checkout - returns a mock connection.
  """
  def checkout(_timeout \\ 5000) do
    {:ok, :mock_connection}
  end

  @doc """
  Mock checkin - always succeeds.
  """
  def checkin(_conn) do
    :ok
  end

  @doc """
  Mock with_connection - executes the function with a mock connection.
  """
  def with_connection(fun, _timeout \\ 5000) do
    fun.(:mock_connection)
  end

  @doc """
  Mock status - returns healthy status.
  """
  def status do
    %{
      connections: 10,
      available: 8,
      busy: 2,
      health: :healthy
    }
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status(), state}
  end

  @impl true
  def handle_call(_, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(_, state) do
    {:noreply, state}
  end
end
