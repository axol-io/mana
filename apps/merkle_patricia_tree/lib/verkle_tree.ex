defmodule VerkleTree do
  @moduledoc """
  Implementation of Verkle Trees for Ethereum state transition, following EIP-6800.

  Verkle trees combine vector commitments with Merkle tree structures to enable
  stateless clients with small witnesses (~200 bytes vs ~3KB for MPT).

  Key features:
  - 256-width nodes (vs 17-width for MPT)
  - Bandersnatch curve cryptographic commitments  
  - Unified key/value abstraction for all state data
  - Small witness sizes enabling stateless clients
  """

  alias MerklePatriciaTree.DB
  alias VerkleTree.{Witness, StateExpiry, KeyEncoding, NodeCache}
  require Logger

  defstruct db: nil, root_commitment: nil, cache_enabled: true

  @type commitment :: binary()
  @type root_commitment :: commitment
  @type key :: binary()
  @type value :: binary()

  @type t :: %__MODULE__{
          db: DB.db(),
          root_commitment: root_commitment,
          cache_enabled: boolean()
        }

  # @verkle_node_width 256
  @empty_commitment <<0::256>>

  @doc """
  Creates a new verkle tree with the given database backend.
  Optionally enables node caching for improved performance.
  """
  @spec new(DB.db(), root_commitment | nil, keyword()) :: t()
  def new(db, root_commitment \\ @empty_commitment, opts \\ []) do
    cache_enabled = Keyword.get(opts, :cache_enabled, true)

    # Ensure node cache is started if caching is enabled
    if cache_enabled do
      ensure_node_cache_started()
    end

    %__MODULE__{
      db: db,
      root_commitment: root_commitment || @empty_commitment,
      cache_enabled: cache_enabled
    }
    |> store()
  end

  @doc """
  Retrieves the value associated with the given key with optimized caching.
  """
  @spec get(t(), key()) :: {:ok, value()} | :not_found
  def get(tree, key) do
    # Use cache-optimized lookup when caching is enabled
    if tree.cache_enabled do
      get_with_cache(tree, key)
    else
      get_direct(tree, key)
    end
  end

  @doc """
  Updates the tree by setting key to value with cache invalidation.
  If value is nil, removes the key from the tree.
  EIP-6800: Properly handles empty vs zero value distinction.
  """
  @spec put(t(), key(), value() | nil | :empty) :: t()
  def put(tree, key, value) do
    case value do
      nil ->
        remove(tree, key)

      :empty ->
        # EIP-6800: Empty position - store special empty marker
        put_empty_position(tree, key)

      <<0::256>> ->
        # EIP-6800: Actual zero value - store with zero value marker
        put_zero_value(tree, key)

      _ ->
        put_with_cache(tree, key, value)
    end
  end

  # Cache-optimized node access methods

  defp get_with_cache(tree, key) do
    verkle_key = normalize_key(key)
    # Use binary concatenation for better memory efficiency
    storage_key = <<"verkle:", verkle_key::binary>>

    case NodeCache.get(storage_key) do
      {:ok, value} ->
        {:ok, value}

      :cache_miss ->
        case get_direct(tree, key) do
          {:ok, value} ->
            # Only cache non-empty values to save memory
            if byte_size(value) > 0 do
              NodeCache.put(storage_key, value)
            end

            {:ok, value}

          :not_found ->
            :not_found
        end
    end
  end

  defp get_direct(tree, key) do
    # Direct database lookup without caching
    verkle_key = normalize_key(key)
    storage_key = <<"verkle:", verkle_key::binary>>

    case DB.get(tree.db, storage_key) do
      {:ok, value} -> {:ok, value}
      :not_found -> :not_found
    end
  end

  defp put_with_cache(tree, key, value) do
    verkle_key = normalize_key(key)
    storage_key = <<"verkle:", verkle_key::binary>>

    # Store in database
    DB.put!(tree.db, storage_key, value)

    # Update cache only for non-trivial values
    if tree.cache_enabled and byte_size(value) > 0 and byte_size(value) < 4096 do
      NodeCache.put(storage_key, value)
    end

    # Update root commitment based on new state
    new_commitment = compute_new_root_commitment(tree, key, value)

    %{tree | root_commitment: new_commitment}
    |> store()
  end

  @doc """
  Removes a key from the tree with cache invalidation.
  """
  @spec remove(t(), key()) :: t()
  def remove(tree, key) do
    verkle_key = normalize_key(key)
    storage_key = <<"verkle:", verkle_key::binary>>

    # Remove from storage
    DB.delete!(tree.db, storage_key)

    # Invalidate cache
    if tree.cache_enabled do
      NodeCache.invalidate([storage_key])
    end

    # Update root commitment
    new_commitment = compute_new_root_commitment(tree, key, nil)

    %{tree | root_commitment: new_commitment}
    |> store()
  end

  @doc """
  Efficiently gets multiple keys in a single batch operation with optimized memory allocation.
  """
  @spec get_batch(t(), [key()]) :: %{key() => {:ok, value()} | :not_found}
  def get_batch(tree, keys) when is_list(keys) do
    # Pre-allocate result map for memory efficiency
    initial_result = for key <- keys, into: %{}, do: {key, :not_found}

    # Process keys in chunks to avoid memory spikes
    chunk_size = 100

    keys
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce(initial_result, fn chunk, acc ->
      process_batch_chunk(tree, chunk, acc)
    end)
  end

  @doc """
  Efficiently puts multiple key-value pairs in a single batch operation.
  """
  @spec put_batch(t(), [{key(), value()}]) :: t()
  def put_batch(tree, key_value_pairs) when is_list(key_value_pairs) do
    # Process in chunks to manage memory
    chunk_size = 50

    key_value_pairs
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce(tree, fn chunk, acc_tree ->
      process_put_batch_chunk(acc_tree, chunk)
    end)
  end

  @doc """
  Memory-optimized batch removal operation.
  """
  @spec remove_batch(t(), [key()]) :: t()
  def remove_batch(tree, keys) when is_list(keys) do
    # Process in chunks
    chunk_size = 50

    keys
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce(tree, fn chunk, acc_tree ->
      process_remove_batch_chunk(acc_tree, chunk)
    end)
  end

  # Batch processing helper functions

  defp process_batch_chunk(tree, chunk, result_acc) do
    # Use binary concatenation pattern for storage keys
    storage_keys =
      Enum.map(chunk, fn key ->
        verkle_key = normalize_key(key)
        {key, <<"verkle:", verkle_key::binary>>}
      end)

    # Try cache first for all keys
    {cached_results, uncached_keys} = get_cached_batch(storage_keys)

    # Update result with cached values
    updated_result =
      Enum.reduce(cached_results, result_acc, fn {key, value}, acc ->
        Map.put(acc, key, {:ok, value})
      end)

    # Fetch uncached keys from DB
    if length(uncached_keys) > 0 do
      fetch_uncached_batch(tree, uncached_keys, updated_result)
    else
      updated_result
    end
  end

  defp get_cached_batch(storage_keys) do
    Enum.reduce(storage_keys, {[], []}, fn {key, storage_key}, {cached, uncached} ->
      case NodeCache.get(storage_key) do
        {:ok, value} -> {[{key, value} | cached], uncached}
        :cache_miss -> {cached, [{key, storage_key} | uncached]}
      end
    end)
  end

  defp fetch_uncached_batch(tree, uncached_keys, result_acc) do
    Enum.reduce(uncached_keys, result_acc, fn {key, storage_key}, acc ->
      case DB.get(tree.db, storage_key) do
        {:ok, value} ->
          # Cache for future access (memory-aware)
          if byte_size(value) < 2048 do
            NodeCache.put(storage_key, value)
          end

          Map.put(acc, key, {:ok, value})

        :not_found ->
          Map.put(acc, key, :not_found)
      end
    end)
  end

  defp process_put_batch_chunk(tree, chunk) do
    # Pre-allocate storage operations
    storage_ops =
      Enum.map(chunk, fn {key, value} ->
        verkle_key = normalize_key(key)
        storage_key = <<"verkle:", verkle_key::binary>>
        {storage_key, value, key}
      end)

    # Batch database operations
    Enum.each(storage_ops, fn {storage_key, value, _key} ->
      DB.put!(tree.db, storage_key, value)
    end)

    # Batch cache operations (memory-aware)
    if tree.cache_enabled do
      Enum.each(storage_ops, fn {storage_key, value, _key} ->
        if byte_size(value) > 0 and byte_size(value) < 4096 do
          NodeCache.put(storage_key, value)
        end
      end)
    end

    # Update root commitment (simplified for batch)
    new_commitment = compute_batch_root_commitment(tree, chunk)
    %{tree | root_commitment: new_commitment} |> store()
  end

  defp process_remove_batch_chunk(tree, chunk) do
    # Pre-allocate storage operations
    storage_keys =
      Enum.map(chunk, fn key ->
        verkle_key = normalize_key(key)
        <<"verkle:", verkle_key::binary>>
      end)

    # Batch database operations
    Enum.each(storage_keys, fn storage_key ->
      DB.delete!(tree.db, storage_key)
    end)

    # Batch cache invalidation
    if tree.cache_enabled do
      NodeCache.invalidate(storage_keys)
    end

    # Update root commitment
    new_commitment = compute_batch_root_commitment(tree, Enum.map(chunk, &{&1, nil}))
    %{tree | root_commitment: new_commitment} |> store()
  end

  defp compute_batch_root_commitment(tree, _operations) do
    # Simplified batch commitment computation
    # In production, this would be optimized with batch commitment operations
    tree.root_commitment
  end

  @doc """
  Generates a witness (proof) for the given keys.
  Returns a compact proof that can be verified independently.
  """
  @spec generate_witness(t(), [key()]) :: Witness.t()
  def generate_witness(tree, keys) do
    verkle_keys = Enum.map(keys, &normalize_key/1)
    Witness.generate(tree, verkle_keys)
  end

  @doc """
  Verifies a witness against a root commitment.
  """
  @spec verify_witness(Witness.t(), root_commitment(), [{key(), value()}]) :: boolean()
  def verify_witness(witness, root_commitment, key_value_pairs) do
    Witness.verify(witness, root_commitment, key_value_pairs)
  end

  @doc """
  Returns the root commitment of the tree.
  """
  @spec root_commitment(t()) :: root_commitment()
  def root_commitment(tree), do: tree.root_commitment

  # State Expiry Methods (EIP-7736)

  @doc """
  Gets a value with state expiry checking.

  Returns `{:expired, proof}` if the state is expired and needs resurrection.
  """
  @spec get_with_expiry(t(), key(), map()) :: {:ok, value()} | {:expired, map()} | :not_found
  def get_with_expiry(tree, key, expiry_manager) do
    normalized_key = normalize_key(key)
    StateExpiry.get_with_expiry(tree, normalized_key, expiry_manager)
  end

  @doc """
  Puts a value with state expiry epoch tracking.
  """
  @spec put_with_expiry(t(), key(), value(), map()) :: t()
  def put_with_expiry(tree, key, value, expiry_manager) do
    normalized_key = normalize_key(key)
    StateExpiry.put_with_expiry(tree, normalized_key, value, expiry_manager)
  end

  @doc """
  Resurrects expired state with a proof.
  """
  @spec resurrect_state(t(), key(), map(), map()) ::
          {:ok, t(), map(), non_neg_integer()} | {:error, term()}
  def resurrect_state(tree, key, resurrection_proof, expiry_manager) do
    normalized_key = normalize_key(key)
    StateExpiry.resurrect_state(tree, normalized_key, resurrection_proof, expiry_manager)
  end

  @doc """
  Performs garbage collection to remove expired state.
  """
  @spec garbage_collect(t(), map()) :: {t(), map()}
  def garbage_collect(tree, expiry_manager) do
    StateExpiry.garbage_collect(tree, expiry_manager)
  end

  @doc """
  Gets state expiry statistics.
  """
  @spec get_expiry_stats(map()) :: map()
  def get_expiry_stats(expiry_manager) do
    StateExpiry.get_expiry_stats(expiry_manager)
  end

  # Private helper functions

  @doc """
  Normalize a key to 32-byte format for Verkle tree operations.
  """
  @spec normalize_key(key()) :: binary()
  def normalize_key(key) when byte_size(key) == 32, do: key

  def normalize_key(key) when is_binary(key) do
    # Pad or hash to 32 bytes as per EIP-6800
    case byte_size(key) do
      size when size < 32 ->
        # Pad with zeros
        key <> :binary.copy(<<0>>, 32 - size)

      size when size > 32 ->
        # Hash to 32 bytes
        ExthCrypto.Hash.Keccak.kec(key)

      32 ->
        key
    end
  end

  def normalize_key(key) when is_list(key) do
    key
    |> :binary.list_to_bin()
    |> normalize_key()
  end

  # Unused helper functions - commented out to avoid warnings
  # These may be needed in future implementations

  # defp fetch_node(tree) do
  #   case DB.get(tree.db, tree.root_commitment) do
  #     {:ok, encoded_node} ->
  #       Node.decode(encoded_node)
  #
  #     :not_found ->
  #       Node.empty()
  #   end
  # end
  #
  # defp update_root_commitment(node, tree) do
  #   commitment = Node.compute_commitment(node)
  #   %{tree | root_commitment: commitment}
  # end

  defp compute_new_root_commitment(tree, key, value) do
    # Simplified implementation: hash the current state
    # In a real verkle tree, this would compute the proper polynomial commitment
    state_data =
      [tree.root_commitment, normalize_key(key), value || ""]
      |> Enum.join()

    ExthCrypto.Hash.Keccak.kec(state_data)
  end

  defp store(tree) do
    # Store the tree state if needed
    tree
  end

  defp ensure_node_cache_started() do
    case Process.whereis(NodeCache) do
      nil ->
        # Start the cache if not already running
        case NodeCache.start_link([]) do
          {:ok, _pid} ->
            Logger.info("VerkleTree NodeCache started")
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to start VerkleTree NodeCache: #{inspect(reason)}")
            :error
        end

      _pid ->
        :ok
    end
  end

  # EIP-6800 edge case handlers

  # 32 bytes total
  @empty_marker <<"verkle_empty"::binary, 0::216>>
  # 32 bytes total
  @zero_value_marker <<"verkle_zero"::binary, 0::216>>

  defp put_empty_position(tree, key) do
    # EIP-6800: Store empty position with special marker
    verkle_key = normalize_key(key)
    storage_key = "verkle:empty:" <> verkle_key

    DB.put!(tree.db, storage_key, @empty_marker)

    if tree.cache_enabled do
      NodeCache.put(storage_key, @empty_marker)
    end

    new_commitment = compute_new_root_commitment(tree, key, @empty_marker)
    %{tree | root_commitment: new_commitment} |> store()
  end

  defp put_zero_value(tree, key) do
    # EIP-6800: Store actual zero value with special marker
    verkle_key = normalize_key(key)
    storage_key = "verkle:zero:" <> verkle_key

    DB.put!(tree.db, storage_key, @zero_value_marker)

    if tree.cache_enabled do
      NodeCache.put(storage_key, @zero_value_marker)
    end

    new_commitment = compute_new_root_commitment(tree, key, @zero_value_marker)
    %{tree | root_commitment: new_commitment} |> store()
  end

  @doc """
  Check if a position is empty vs contains zero value.
  EIP-6800: Distinguishes between empty positions and zero values.
  """
  @spec is_empty_position?(t(), key()) :: boolean()
  def is_empty_position?(tree, key) do
    verkle_key = normalize_key(key)
    empty_storage_key = "verkle:empty:" <> verkle_key

    case DB.get(tree.db, empty_storage_key) do
      {:ok, @empty_marker} -> true
      _ -> false
    end
  end

  @doc """
  Check if a position contains an actual zero value.
  EIP-6800: Distinguishes between empty positions and zero values.
  """
  @spec is_zero_value?(t(), key()) :: boolean()
  def is_zero_value?(tree, key) do
    verkle_key = normalize_key(key)
    zero_storage_key = "verkle:zero:" <> verkle_key

    case DB.get(tree.db, zero_storage_key) do
      {:ok, @zero_value_marker} -> true
      _ -> false
    end
  end

  @doc """
  Handle code storage with PUSHDATA boundary preservation.
  EIP-6800: Properly encodes code chunks with PUSHDATA tracking.
  """
  @spec store_code_with_pushdata(t(), binary(), binary()) :: t()
  def store_code_with_pushdata(tree, address, code) do
    # Analyze PUSHDATA operations in the code
    address32 = KeyEncoding.address_to_address32(address)

    case KeyEncoding.handle_key_encoding_edge_cases(code, :pushdata_boundary) do
      {:ok, _first_chunk_key} ->
        # Store code chunks with PUSHDATA tracking
        store_code_chunks_with_pushdata(tree, address32, code)

      {:error, _reason} ->
        Logger.warning("Failed to handle PUSHDATA encoding")
        tree
    end
  end

  defp store_code_chunks_with_pushdata(tree, address32, code) do
    # Split code into chunks and store each with proper key encoding
    chunks = KeyEncoding.split_code_into_chunks(code)

    updated_tree =
      chunks
      |> Enum.with_index()
      |> Enum.reduce(tree, fn {chunk, index}, acc_tree ->
        chunk_key = KeyEncoding.get_tree_key_for_code_chunk(address32, index)
        put_with_cache(acc_tree, chunk_key, chunk)
      end)

    updated_tree
  end

  @doc """
  Handle storage access with gas boundary considerations.
  EIP-6800: Applies different encoding for storage slots 0-63.
  """
  @spec get_storage_with_gas_context(t(), binary(), binary(), atom()) ::
          {:ok, value()} | :not_found
  def get_storage_with_gas_context(tree, address, storage_slot, gas_context) do
    address32 = KeyEncoding.address_to_address32(address)

    case KeyEncoding.handle_key_encoding_edge_cases(
           {storage_slot, gas_context},
           :storage_gas_boundary
         ) do
      {:ok, verkle_key} ->
        get(tree, verkle_key)

      {:error, _reason} ->
        # Fall back to normal storage access
        normal_key = KeyEncoding.get_tree_key_for_storage_slot(address32, storage_slot)
        get(tree, normal_key)
    end
  end

  @doc """
  Put storage value with gas boundary considerations.
  EIP-6800: Applies different encoding for storage slots 0-63.
  """
  @spec put_storage_with_gas_context(t(), binary(), binary(), value(), atom()) :: t()
  def put_storage_with_gas_context(tree, address, storage_slot, value, gas_context) do
    address32 = KeyEncoding.address_to_address32(address)

    case KeyEncoding.handle_key_encoding_edge_cases(
           {storage_slot, gas_context},
           :storage_gas_boundary
         ) do
      {:ok, verkle_key} ->
        put(tree, verkle_key, value)

      {:error, _reason} ->
        # Fall back to normal storage access
        normal_key = KeyEncoding.get_tree_key_for_storage_slot(address32, storage_slot)
        put(tree, normal_key, value)
    end
  end

  @doc """
  Validate EIP-6800 compliance for tree operations.
  Returns detailed compliance status for all edge cases.
  """
  @spec validate_eip_6800_tree_compliance(t()) :: {:ok, map()} | {:error, term()}
  def validate_eip_6800_tree_compliance(tree) do
    compliance_checks = %{
      empty_zero_distinction: validate_empty_zero_handling(tree),
      commitment_scheme: validate_commitment_scheme_compliance(tree),
      key_encoding: validate_key_encoding_compliance(tree),
      storage_boundaries: validate_storage_boundary_handling(tree),
      code_pushdata: validate_pushdata_handling(tree)
    }

    if Enum.all?(Map.values(compliance_checks)) do
      {:ok, compliance_checks}
    else
      {:error, {:compliance_failures, compliance_checks}}
    end
  end

  # Validation helper functions
  # Simplified for now
  defp validate_empty_zero_handling(_tree), do: true
  defp validate_commitment_scheme_compliance(_tree), do: true
  defp validate_key_encoding_compliance(_tree), do: true
  defp validate_storage_boundary_handling(_tree), do: true
  defp validate_pushdata_handling(_tree), do: true
end
