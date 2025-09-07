defmodule MerkleTree do
  @moduledoc """
  Simple Merkle tree implementation for inclusion proofs.

  Used for Layer 2 bridge cross-layer message verification.
  """

  use Bitwise
  require Logger

  @doc """
  Generate a Merkle proof for an element at a given index.
  """
  def generate_proof(elements, index, _root) when is_list(elements) and is_integer(index) do
    tree = build_tree(elements)
    proof = build_proof(tree, index)
    {:ok, proof}
  rescue
    error ->
      Logger.error("Failed to generate Merkle proof: #{inspect(error)}")
      {:error, :proof_generation_failed}
  end

  @doc """
  Verify a Merkle proof.
  """
  def verify_proof(element, proof, root) do
    computed_root = compute_root(element, proof)
    computed_root == root
  end

  @doc """
  Build a Merkle tree from a list of elements.
  """
  def build_tree(elements) when is_list(elements) do
    leaves = Enum.map(elements, &hash/1)
    build_tree_recursive(leaves)
  end

  @doc """
  Get the root of a Merkle tree.
  """
  def root(tree) do
    case tree do
      %{root: root} -> root
      [root] -> root
      _ -> hash(tree)
    end
  end

  # Private functions

  defp build_tree_recursive([single]), do: single

  defp build_tree_recursive(nodes) do
    next_level =
      nodes
      |> Enum.chunk_every(2)
      |> Enum.map(fn
        [left, right] -> hash(left <> right)
        [single] -> single
      end)

    build_tree_recursive(next_level)
  end

  defp build_proof(tree, index) do
    # Simplified proof generation
    # In production, this would build the actual sibling path
    %{
      index: index,
      siblings: [],
      root: root(tree)
    }
  end

  defp compute_root(element, proof) do
    # Simplified root computation
    # In production, this would hash up the tree with siblings
    leaf_hash = hash(element)

    Enum.reduce(proof.siblings, leaf_hash, fn sibling, current ->
      if proof.index &&& 1 == 0 do
        hash(current <> sibling)
      else
        hash(sibling <> current)
      end
    end)
  end

  defp hash(data) do
    :crypto.hash(:sha256, data)
  end
end
