defmodule ExWire.Layer2.ZK.StateTree do
  @moduledoc """
  Sparse Merkle Tree implementation for ZK rollup state management.
  Optimized for zkEVM state storage with account and storage trees.
  """

  require Logger
  import Bitwise

  @type t :: %__MODULE__{
          depth: non_neg_integer(),
          root: binary(),
          nodes: map(),
          default_value: binary()
        }

  defstruct [
    :depth,
    :root,
    :nodes,
    :default_value
  ]

  @empty_hash <<0::256>>

  @doc """
  Creates a new state tree with specified depth.
  """
  @spec new(non_neg_integer()) :: {:ok, t()}
  def new(depth \\ 32) when depth > 0 and depth <= 256 do
    tree = %__MODULE__{
      depth: depth,
      root: compute_empty_root(depth),
      nodes: %{},
      default_value: @empty_hash
    }

    {:ok, tree}
  end

  @doc """
  Gets the current root hash of the tree.
  """
  @spec get_root(t()) :: binary()
  def get_root(%__MODULE__{root: root}), do: root

  @doc """
  Updates an account in the state tree.
  """
  @spec update_account(t(), binary(), map()) :: {:ok, t()} | {:error, term()}
  def update_account(tree, account_address, account_state) do
    # Convert address to tree index
    index = address_to_index(account_address, tree.depth)

    # Encode account state
    value = encode_account_state(account_state)

    # Update tree
    update_leaf(tree, index, value)
  end

  @doc """
  Gets an account from the state tree.
  """
  @spec get_account(t(), binary()) :: {:ok, map()} | {:error, :not_found}
  def get_account(tree, account_address) do
    index = address_to_index(account_address, tree.depth)

    case get_leaf(tree, index) do
      {:ok, value} when value != @empty_hash ->
        {:ok, decode_account_state(value)}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Updates a leaf in the tree at the given index.
  """
  @spec update_leaf(t(), non_neg_integer(), binary()) :: {:ok, t()} | {:error, term()}
  def update_leaf(tree, index, value) do
    max_index = :math.pow(2, tree.depth) |> round()

    if index >= max_index do
      {:error, :index_out_of_bounds}
    else
      # Build path from leaf to root
      path = build_path(index, tree.depth)

      # Update nodes along the path
      {new_nodes, new_root} = update_path(tree.nodes, path, value, tree.depth)

      {:ok, %{tree | nodes: new_nodes, root: new_root}}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Gets a leaf value at the given index.
  """
  @spec get_leaf(t(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def get_leaf(tree, index) do
    max_index = :math.pow(2, tree.depth) |> round()

    if index >= max_index do
      {:error, :index_out_of_bounds}
    else
      path = build_path(index, tree.depth)

      value = traverse_path(tree.nodes, path, tree.depth, tree.default_value)
      {:ok, value}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Generates a Merkle proof for a leaf at the given index.
  """
  @spec generate_proof(t(), non_neg_integer()) :: {:ok, list(binary())} | {:error, term()}
  def generate_proof(tree, index) do
    max_index = :math.pow(2, tree.depth) |> round()

    if index >= max_index do
      {:error, :index_out_of_bounds}
    else
      path = build_path(index, tree.depth)
      siblings = collect_siblings(tree.nodes, path, tree.depth, tree.default_value)

      {:ok, siblings}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Verifies a Merkle proof for a value at the given index.
  """
  @spec verify_proof(binary(), non_neg_integer(), binary(), list(binary())) :: boolean()
  def verify_proof(root, index, value, proof) do
    computed_root =
      Enum.reduce(Enum.with_index(proof), value, fn {sibling, level}, acc ->
        if bit_set?(index, level) do
          hash_pair(sibling, acc)
        else
          hash_pair(acc, sibling)
        end
      end)

    computed_root == root
  end

  @doc """
  Batch updates multiple leaves efficiently.
  """
  @spec batch_update(t(), list({non_neg_integer(), binary()})) :: {:ok, t()} | {:error, term()}
  def batch_update(tree, updates) do
    # Sort updates by index for efficient processing
    sorted_updates = Enum.sort_by(updates, &elem(&1, 0))

    # Apply updates
    result =
      Enum.reduce_while(sorted_updates, {:ok, tree}, fn {index, value}, {:ok, acc_tree} ->
        case update_leaf(acc_tree, index, value) do
          {:ok, new_tree} -> {:cont, {:ok, new_tree}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    result
  end

  # Private Functions

  defp compute_empty_root(0), do: @empty_hash

  defp compute_empty_root(depth) do
    child_hash = compute_empty_root(depth - 1)
    hash_pair(child_hash, child_hash)
  end

  defp address_to_index(address, depth) do
    # Convert address to index in the tree
    # Use the first 'depth' bits of the address hash
    hash = :crypto.hash(:sha256, address)

    <<index::size(depth), _::binary>> = hash
    index
  end

  defp encode_account_state(_state) do
    # Encode account state for storage
    encoded = %{
      balance: state[:balance] || 0,
      nonce: state[:nonce] || 0,
      storage_root: state[:storage_root] || @empty_hash,
      code_hash: state[:code_hash] || @empty_hash
    }

    :erlang.term_to_binary(encoded)
  end

  defp decode_account_state(binary) do
    :erlang.binary_to_term(binary)
  end

  defp build_path(index, depth) do
    # Build bit path from index
    for i <- 0..(depth - 1) do
      bit_set?(index, i)
    end
    |> Enum.reverse()
  end

  defp bit_set?(number, position) do
    (number >>> position &&& 1) == 1
  end

  defp update_path(nodes, path, value, depth) do
    do_update_path(nodes, path, value, depth, [])
  end

  defp do_update_path(_nodes, [], value, 0, _prefix) do
    {%{}, value}
  end

  defp do_update_path(nodes, [bit | rest_path], value, level, prefix) do
    current_key = prefix

    # Recursively update child
    child_prefix = prefix ++ [bit]
    {child_nodes, child_hash} = do_update_path(nodes, rest_path, value, level - 1, child_prefix)

    # Get sibling hash
    sibling_bit = not bit
    sibling_key = prefix ++ [sibling_bit]
    sibling_hash = Map.get(nodes, sibling_key, compute_default_hash(level - 1))

    # Compute new hash for this level
    new_hash =
      if bit do
        hash_pair(sibling_hash, child_hash)
      else
        hash_pair(child_hash, sibling_hash)
      end

    # Update nodes map
    new_nodes =
      child_nodes
      |> Map.put(child_prefix, child_hash)
      |> Map.put(current_key, new_hash)

    {new_nodes, new_hash}
  end

  defp traverse_path(nodes, path, depth, default) do
    do_traverse_path(nodes, path, depth, [], default)
  end

  defp do_traverse_path(_nodes, [], 0, prefix, default) do
    Map.get(prefix, prefix, default)
  end

  defp do_traverse_path(nodes, [bit | rest_path], level, prefix, default) do
    child_prefix = prefix ++ [bit]

    case Map.get(nodes, child_prefix) do
      nil -> default
      _value -> do_traverse_path(nodes, rest_path, level - 1, child_prefix, default)
    end
  end

  defp collect_siblings(nodes, path, depth, default) do
    do_collect_siblings(nodes, path, depth, [], default, [])
  end

  defp do_collect_siblings(_nodes, [], 0, _prefix, _default, siblings) do
    Enum.reverse(siblings)
  end

  defp do_collect_siblings(nodes, [bit | rest_path], level, prefix, default, siblings) do
    sibling_bit = not bit
    sibling_key = prefix ++ [sibling_bit]
    sibling_hash = Map.get(nodes, sibling_key, compute_default_hash(level - 1))

    child_prefix = prefix ++ [bit]

    do_collect_siblings(
      nodes,
      rest_path,
      level - 1,
      child_prefix,
      default,
      [sibling_hash | siblings]
    )
  end

  defp compute_default_hash(0), do: @empty_hash

  defp compute_default_hash(level) do
    child = compute_default_hash(level - 1)
    hash_pair(child, child)
  end

  defp hash_pair(left, right) do
    :crypto.hash(:sha256, left <> right)
  end
end
