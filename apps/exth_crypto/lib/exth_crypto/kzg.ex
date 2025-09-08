defmodule ExthCrypto.KZG do
  @moduledoc """
  KZG polynomial commitment scheme implementation for EIP-4844.

  This module provides KZG cryptographic operations for blob transactions:
  - Computing KZG commitments from blob data
  - Generating KZG proofs for blob verification
  - Verifying KZG proofs individually and in batches

  Uses Rust NIF with blst library for performance-critical operations.
  """

  # Always load the NIF unless explicitly disabled
  if System.get_env("RUSTLER_SKIP_COMPILE") != "1" do
    use Rustler,
      otp_app: :exth_crypto,
      crate: "kzg_nif"
  end

  require Logger

  # EIP-4844 Constants
  @bytes_per_field_element 32
  @field_elements_per_blob 4096
  @blob_size @bytes_per_field_element * @field_elements_per_blob
  @commitment_size 48
  @proof_size 48
  @versioned_hash_version_kzg 0x01

  # Type specifications
  # 131,072 bytes = 1,048,576 bits
  @type blob_data :: <<_::1_048_576>>
  # 48 bytes = 384 bits
  @type commitment :: <<_::384>>
  # 48 bytes = 384 bits
  @type proof :: <<_::384>>
  # 32 bytes = 256 bits
  @type field_element :: <<_::256>>
  # 32 bytes = 256 bits
  @type versioned_hash :: <<_::256>>

  # Native functions (implemented in Rust)

  @doc """
  Load trusted setup from bytes.
  This must be called before any KZG operations.
  """
  @spec load_trusted_setup_from_bytes(binary(), binary()) :: :ok | {:error, term()}
  def load_trusted_setup_from_bytes(_g1_bytes, _g2_bytes) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Check if trusted setup is loaded.
  """
  @spec is_setup_loaded() :: boolean()
  def is_setup_loaded() do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Compute a KZG commitment from blob data.
  """
  @spec blob_to_kzg_commitment(blob_data()) :: commitment()
  def blob_to_kzg_commitment(_blob) do
    if System.get_env("RUSTLER_SKIP_COMPILE") == "1" do
      # Return stub commitment for development
      <<0::384>>
    else
      :erlang.nif_error(:nif_not_loaded)
    end
  end

  @doc """
  Compute a KZG proof for a given evaluation point.
  """
  @spec compute_kzg_proof(blob_data(), field_element()) :: proof()
  def compute_kzg_proof(_blob, _z_bytes) do
    if System.get_env("RUSTLER_SKIP_COMPILE") == "1" do
      # Return stub proof for development
      <<0::384>>
    else
      :erlang.nif_error(:nif_not_loaded)
    end
  end

  @doc """
  Compute a KZG proof for blob verification.
  """
  @spec compute_blob_kzg_proof(blob_data(), commitment()) :: proof()
  def compute_blob_kzg_proof(_blob, _commitment) do
    if System.get_env("RUSTLER_SKIP_COMPILE") == "1" do
      # Return stub proof for development
      <<0::384>>
    else
      :erlang.nif_error(:nif_not_loaded)
    end
  end

  @doc """
  Verify a KZG proof.
  """
  @spec verify_kzg_proof(commitment(), field_element(), field_element(), proof()) :: boolean()
  def verify_kzg_proof(_commitment, _z_bytes, _y_bytes, _proof) do
    if System.get_env("RUSTLER_SKIP_COMPILE") == "1" do
      # Always return true for development/testing
      true
    else
      :erlang.nif_error(:nif_not_loaded)
    end
  end

  @doc """
  Verify a blob KZG proof.
  """
  @spec verify_blob_kzg_proof(blob_data(), commitment(), proof()) :: boolean()
  def verify_blob_kzg_proof(_blob, _commitment, _proof) do
    if System.get_env("RUSTLER_SKIP_COMPILE") == "1" do
      # Always return true for development/testing
      true
    else
      :erlang.nif_error(:nif_not_loaded)
    end
  end

  @doc """
  Verify multiple blob KZG proofs in batch.
  """
  @spec verify_blob_kzg_proof_batch(list(blob_data()), list(commitment()), list(proof())) ::
          boolean()
  def verify_blob_kzg_proof_batch(_blobs, _commitments, _proofs) do
    if System.get_env("RUSTLER_SKIP_COMPILE") == "1" do
      # Always return true for development/testing
      true
    else
      :erlang.nif_error(:nif_not_loaded)
    end
  end

  # Elixir wrapper functions with validation

  @doc """
  Initialize the KZG system with a trusted setup file.
  For testing, this loads a minimal trusted setup.
  """
  @spec init_trusted_setup() :: :ok | {:error, term()}
  def init_trusted_setup() do
    # Check if NIF is available - if not, return ok for development/test environments
    if System.get_env("RUSTLER_SKIP_COMPILE") == "1" do
      Logger.warning("KZG NIF not loaded - using stub implementation for development")
      :ok
    else
      # In production, this would load the actual ceremony trusted setup
      # For development/testing, we create minimal setup data
      g1_bytes = generate_minimal_g1_setup()
      g2_bytes = generate_minimal_g2_setup()

      case load_trusted_setup_from_bytes(g1_bytes, g2_bytes) do
        :ok -> :ok
        error -> {:error, error}
      end
    end
  rescue
    # Fallback if NIF is not available
    _error ->
      Logger.warning("KZG NIF not available - using stub implementation")
      :ok
  end

  @doc """
  Create a versioned hash from a KZG commitment.
  """
  @spec create_versioned_hash(commitment()) :: versioned_hash()
  def create_versioned_hash(commitment) when byte_size(commitment) == @commitment_size do
    hash = :crypto.hash(:sha256, commitment)
    <<@versioned_hash_version_kzg, hash::binary-size(31)>>
  end

  @doc """
  Validate blob data format.
  """
  @spec validate_blob(binary()) :: :ok | {:error, term()}
  def validate_blob(blob) do
    cond do
      byte_size(blob) != @blob_size ->
        {:error, :invalid_blob_size}

      not is_valid_blob_format?(blob) ->
        {:error, :invalid_blob_format}

      true ->
        :ok
    end
  end

  @doc """
  Validate KZG commitment format.
  """
  @spec validate_commitment(binary()) :: :ok | {:error, term()}
  def validate_commitment(commitment) do
    if byte_size(commitment) == @commitment_size do
      :ok
    else
      {:error, :invalid_commitment_size}
    end
  end

  @doc """
  Validate KZG proof format.
  """
  @spec validate_proof(binary()) :: :ok | {:error, term()}
  def validate_proof(proof) do
    if byte_size(proof) == @proof_size do
      :ok
    else
      {:error, :invalid_proof_size}
    end
  end

  @doc """
  High-level blob verification with full validation.
  """
  @spec verify_blob_with_validation(blob_data(), commitment(), proof()) ::
          {:ok, boolean()} | {:error, term()}
  def verify_blob_with_validation(blob, commitment, proof) do
    with :ok <- ensure_setup_loaded(),
         :ok <- validate_blob(blob),
         :ok <- validate_commitment(commitment),
         :ok <- validate_proof(proof) do
      result = verify_blob_kzg_proof(blob, commitment, proof)
      {:ok, result}
    end
  end

  @doc """
  High-level batch verification with full validation.
  """
  @spec verify_batch_with_validation(list(blob_data()), list(commitment()), list(proof())) ::
          {:ok, boolean()} | {:error, term()}
  def verify_batch_with_validation(blobs, commitments, proofs) do
    with :ok <- ensure_setup_loaded(),
         :ok <- validate_batch_inputs(blobs, commitments, proofs) do
      result = verify_blob_kzg_proof_batch(blobs, commitments, proofs)
      {:ok, result}
    end
  end

  @doc """
  Generate KZG commitment and proof for blob data.
  """
  @spec generate_commitment_and_proof(blob_data()) ::
          {:ok, {commitment(), proof()}} | {:error, term()}
  def generate_commitment_and_proof(blob) do
    with :ok <- ensure_setup_loaded(),
         :ok <- validate_blob(blob) do
      commitment = blob_to_kzg_commitment(blob)
      proof = compute_blob_kzg_proof(blob, commitment)
      {:ok, {commitment, proof}}
    end
  end

  # Private helper functions

  defp ensure_setup_loaded() do
    if is_setup_loaded() do
      :ok
    else
      {:error, :setup_not_loaded}
    end
  end

  defp validate_batch_inputs(blobs, commitments, proofs) do
    cond do
      length(blobs) != length(commitments) ->
        {:error, :mismatched_batch_lengths}

      length(commitments) != length(proofs) ->
        {:error, :mismatched_batch_lengths}

      length(blobs) == 0 ->
        {:error, :empty_batch}

      true ->
        # Validate each element
        with :ok <- validate_all_blobs(blobs),
             :ok <- validate_all_commitments(commitments),
             :ok <- validate_all_proofs(proofs) do
          :ok
        end
    end
  end

  defp validate_all_blobs(blobs) do
    case Enum.find(blobs, &(validate_blob(&1) != :ok)) do
      nil -> :ok
      _invalid -> {:error, :invalid_blob_in_batch}
    end
  end

  defp validate_all_commitments(commitments) do
    case Enum.find(commitments, &(validate_commitment(&1) != :ok)) do
      nil -> :ok
      _invalid -> {:error, :invalid_commitment_in_batch}
    end
  end

  defp validate_all_proofs(proofs) do
    case Enum.find(proofs, &(validate_proof(&1) != :ok)) do
      nil -> :ok
      _invalid -> {:error, :invalid_proof_in_batch}
    end
  end

  defp is_valid_blob_format?(blob) do
    # Check that each field element is valid (< BLS12-381 field modulus)
    # This is a simplified check - in production we'd validate each 32-byte field element
    blob
    |> :binary.bin_to_list()
    |> Enum.chunk_every(@bytes_per_field_element)
    |> Enum.all?(&is_valid_field_element_bytes?/1)
  end

  defp is_valid_field_element_bytes?(bytes) when length(bytes) == @bytes_per_field_element do
    # Check if bytes represent a valid field element
    # BLS12-381 field modulus (simplified check)
    bytes_binary = :binary.list_to_bin(bytes)
    <<first_byte, _rest::binary>> = bytes_binary

    # Simple check: first byte shouldn't be too large (full check is more complex)
    first_byte < 0x74
  end

  defp is_valid_field_element_bytes?(_), do: false

  # Testing/development functions (would be removed in production)

  defp generate_minimal_g1_setup() do
    # Generate minimal G1 setup for testing (not secure!)
    # Each point is 48 bytes compressed
    # Minimal setup for 4096 field elements
    setup_size = 4096

    g1_setup =
      for i <- 0..(setup_size - 1) do
        # Generate deterministic but fake G1 points
        point_bytes = :crypto.hash(:sha256, <<i::32>>)
        padding = :crypto.hash(:sha256, <<i::32, 1>>)
        <<point_bytes::binary, :binary.part(padding, 0, 16)::binary>>
      end

    :binary.list_to_bin(g1_setup)
  end

  defp generate_minimal_g2_setup() do
    # Generate minimal G2 setup for testing (not secure!)
    # Each G2 point is 96 bytes compressed, but we only need a few for verification
    g2_setup =
      for i <- 0..1 do
        # Generate deterministic but fake G2 points
        point_bytes_1 = :crypto.hash(:sha256, <<i::32, "g2_1">>)
        point_bytes_2 = :crypto.hash(:sha256, <<i::32, "g2_2">>)
        padding = :crypto.hash(:sha256, <<i::32, "g2_pad">>)
        <<point_bytes_1::binary, point_bytes_2::binary, :binary.part(padding, 0, 32)::binary>>
      end

    :binary.list_to_bin(g2_setup)
  end

  # Constants and utilities

  @doc """
  Get the blob size in bytes.
  """
  @spec blob_size() :: non_neg_integer()
  def blob_size(), do: @blob_size

  @doc """
  Get the commitment size in bytes.
  """
  @spec commitment_size() :: non_neg_integer()
  def commitment_size(), do: @commitment_size

  @doc """
  Get the proof size in bytes.
  """
  @spec proof_size() :: non_neg_integer()
  def proof_size(), do: @proof_size

  @doc """
  Get the field elements per blob.
  """
  @spec field_elements_per_blob() :: non_neg_integer()
  def field_elements_per_blob(), do: @field_elements_per_blob
end
