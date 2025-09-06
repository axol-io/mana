defmodule MerklePatriciaTree.Test.Helper do
  @moduledoc """
  Test helper utilities for MerklePatriciaTree tests.

  Provides utilities for:
  - Setting up mock databases
  - Creating test data
  - Managing test environments
  """

  alias MerklePatriciaTree.Test.{AntiodoteMock, AntidoteClientMock, AntidoteConnectionPoolMock}

  @doc """
  Sets up the test environment to use mocks instead of real AntidoteDB.

  Call this in your test setup to avoid network calls and speed up tests.
  """
  def setup_mocks do
    # Replace the real modules with mocks in the application environment
    Application.put_env(:merkle_patricia_tree, :db_module, AntiodoteMock)
    Application.put_env(:merkle_patricia_tree, :antidote_client, AntidoteClientMock)
    Application.put_env(:merkle_patricia_tree, :connection_pool, AntidoteConnectionPoolMock)

    # Start the mock connection pool
    {:ok, _} = AntidoteConnectionPoolMock.start_link()

    :ok
  end

  @doc """
  Tears down the test mocks and restores original configuration.
  """
  def teardown_mocks do
    # Stop any running mock processes
    Process.whereis(AntidoteConnectionPoolMock) && GenServer.stop(AntidoteConnectionPoolMock)

    # Restore original configuration
    Application.delete_env(:merkle_patricia_tree, :db_module)
    Application.delete_env(:merkle_patricia_tree, :antidote_client)
    Application.delete_env(:merkle_patricia_tree, :connection_pool)

    :ok
  end

  @doc """
  Creates a mock database for testing.

  Returns a database reference that can be used with MerklePatriciaTree.DB functions.
  """
  def create_mock_db(name \\ "test") do
    AntiodoteMock.init(name)
  end

  @doc """
  Cleans up a mock database after testing.
  """
  def cleanup_mock_db({AntiodoteMock, agent_name}) do
    AntiodoteMock.stop({AntiodoteMock, agent_name})
  end

  @doc """
  Creates test key-value pairs for database testing.
  """
  def create_test_data(count \\ 10) do
    Enum.map(1..count, fn i ->
      key = "key_#{i}" |> :erlang.term_to_binary()
      value = "value_#{i}" |> :erlang.term_to_binary()
      {key, value}
    end)
  end

  @doc """
  Populates a database with test data.
  """
  def populate_db(db_ref, data) do
    Enum.each(data, fn {key, value} ->
      module = get_db_module()
      module.put!(db_ref, key, value)
    end)

    :ok
  end

  @doc """
  Verifies that all test data exists in the database.
  """
  def verify_data_exists(db_ref, data) do
    module = get_db_module()

    Enum.all?(data, fn {key, expected_value} ->
      case module.get(db_ref, key) do
        {:ok, actual_value} -> actual_value == expected_value
        _ -> false
      end
    end)
  end

  @doc """
  Gets the configured database module (real or mock).
  """
  def get_db_module do
    Application.get_env(:merkle_patricia_tree, :db_module, MerklePatriciaTree.DB.Antidote)
  end

  @doc """
  Gets the configured AntidoteClient module (real or mock).
  """
  def get_antidote_client do
    Application.get_env(
      :merkle_patricia_tree,
      :antidote_client,
      MerklePatriciaTree.DB.AntidoteClient
    )
  end

  @doc """
  Gets the configured connection pool module (real or mock).
  """
  def get_connection_pool do
    Application.get_env(
      :merkle_patricia_tree,
      :connection_pool,
      MerklePatriciaTree.DB.AntidoteConnectionPool
    )
  end

  @doc """
  Benchmarks a function execution time.

  Useful for performance testing.
  """
  def benchmark(name, fun) do
    start_time = System.monotonic_time(:microsecond)
    result = fun.()
    end_time = System.monotonic_time(:microsecond)

    elapsed = end_time - start_time
    IO.puts("#{name}: #{elapsed}μs (#{elapsed / 1000}ms)")

    result
  end

  @doc """
  Creates a test trie with mock database.
  """
  def create_test_trie(name \\ "test_trie") do
    db_ref = create_mock_db(name)
    MerklePatriciaTree.Trie.new(db_ref)
  end

  @doc """
  Asserts that a trie operation succeeds.
  """
  defmacro assert_trie_success(operation) do
    quote do
      result = unquote(operation)

      assert match?({:ok, _}, result) or match?(%MerklePatriciaTree.Trie{}, result),
             "Expected successful trie operation, got: #{inspect(result)}"

      result
    end
  end

  @doc """
  Asserts that a trie contains a specific key-value pair.
  """
  def assert_trie_contains(trie, key, expected_value) do
    case MerklePatriciaTree.Trie.get(trie, key) do
      {:ok, actual_value} ->
        unless actual_value == expected_value do
          raise "Trie value mismatch. Expected: #{inspect(expected_value)}, Got: #{inspect(actual_value)}"
        end

        true

      _ ->
        raise "Key not found in trie: #{inspect(key)}"
    end
  end
end
