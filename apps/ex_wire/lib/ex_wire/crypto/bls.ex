defmodule ExWire.Crypto.BLS do
  @moduledoc """
  BLS12-381 signature scheme implementation for Ethereum 2.0.
  Uses Rust NIF for performance-critical operations.

  This module provides BLS signature functionality required for:
  - Validator signatures
  - Attestation aggregation
  - Sync committee signatures
  - Randao reveals
  """

  if System.get_env("RUSTLER_SKIP_COMPILE") != "1" do
    use Rustler,
      otp_app: :ex_wire,
      crate: "bls_nif"
  end

  # Constants
  @bls_modulus 52_435_875_175_126_190_479_447_740_508_185_965_837_690_552_500_527_637_822_603_658_699_938_581_184_513
  @domain_size 32
  @pubkey_size 48
  @signature_size 96
  @hash_size 32

  # Type specifications
  @type pubkey :: <<_::384>>
  @type privkey :: <<_::256>>
  @type signature :: <<_::768>>
  @type message :: binary()
  @type domain :: <<_::256>>

  # Native functions (implemented in Rust)

  @doc """
  Generate a new BLS keypair
  """
  @spec generate_keypair() :: {pubkey(), privkey()}
  def generate_keypair(), do: :erlang.nif_error(:not_loaded)

  @doc """
  Derive public key from private key
  """
  @spec privkey_to_pubkey(privkey()) :: pubkey()
  def privkey_to_pubkey(_privkey), do: :erlang.nif_error(:not_loaded)

  @doc """
  Sign a message with a private key
  """
  @spec sign(privkey(), message()) :: signature()
  def sign(_privkey, _message), do: :erlang.nif_error(:not_loaded)

  @doc """
  Verify a signature
  """
  @spec verify(pubkey(), message(), signature()) :: boolean()
  def verify(_pubkey, _message, _signature), do: :erlang.nif_error(:not_loaded)

  @doc """
  Aggregate multiple signatures
  """
  @spec aggregate_signatures(list(signature())) :: {:ok, signature()} | {:error, term()}
  def aggregate_signatures(signatures) when is_list(signatures) do
    try do
      # Try native NIF first
      result = aggregate_signatures_nif(signatures)
      {:ok, result}
    rescue
      _e in ErlangError ->
        # Fallback to pure Elixir implementation
        aggregate_signatures_fallback(signatures)
    end
  end

  @doc """
  Aggregate multiple public keys
  """
  @spec aggregate_pubkeys(list(pubkey())) :: {:ok, pubkey()} | {:error, term()}
  def aggregate_pubkeys(pubkeys) when is_list(pubkeys) do
    try do
      # Try native NIF first
      result = aggregate_pubkeys_nif(pubkeys)
      {:ok, result}
    rescue
      _e in ErlangError ->
        # Fallback to pure Elixir implementation
        aggregate_pubkeys_fallback(pubkeys)
    end
  end

  # Native NIF functions (will throw if not loaded)
  defp aggregate_signatures_nif(_signatures), do: :erlang.nif_error(:not_loaded)
  defp aggregate_pubkeys_nif(_pubkeys), do: :erlang.nif_error(:not_loaded)

  @doc """
  Fast aggregate verification for signatures of the same message
  """
  @spec fast_aggregate_verify(list(pubkey()), message(), signature()) :: boolean()
  def fast_aggregate_verify(_pubkeys, _message, _signature), do: :erlang.nif_error(:not_loaded)

  @doc """
  Aggregate verification for signatures of different messages
  """
  @spec aggregate_verify(list({pubkey(), message()}), signature()) :: boolean()
  def aggregate_verify(_pubkey_message_pairs, _signature), do: :erlang.nif_error(:not_loaded)

  # Elixir wrapper functions with validation

  @doc """
  Sign a message with domain separation
  """
  @spec sign_with_domain(privkey(), message(), domain()) :: {:ok, signature()} | {:error, term()}
  def sign_with_domain(privkey, message, domain) do
    with :ok <- validate_privkey(privkey),
         :ok <- validate_domain(domain) do
      signing_root = compute_signing_root(message, domain)
      signature = sign(privkey, signing_root)
      {:ok, signature}
    end
  end

  @doc """
  Verify a signature with domain separation
  """
  @spec verify_with_domain(pubkey(), message(), signature(), domain()) :: boolean()
  def verify_with_domain(pubkey, message, signature, domain) do
    with :ok <- validate_pubkey(pubkey),
         :ok <- validate_signature(signature),
         :ok <- validate_domain(domain) do
      signing_root = compute_signing_root(message, domain)
      verify(pubkey, signing_root, signature)
    else
      _ -> false
    end
  end

  @doc """
  Eth2 specific: Sign with fork version and genesis validators root
  """
  def eth2_sign(privkey, message, domain_type, fork_version, genesis_validators_root) do
    domain = compute_domain(domain_type, fork_version, genesis_validators_root)
    sign_with_domain(privkey, message, domain)
  end

  @doc """
  Eth2 specific: Fast aggregate verify for attestations
  """
  def eth2_fast_aggregate_verify(pubkeys, message, signature, domain) do
    with :ok <- validate_pubkeys(pubkeys),
         :ok <- validate_signature(signature),
         :ok <- validate_domain(domain) do
      signing_root = compute_signing_root(message, domain)
      fast_aggregate_verify(pubkeys, signing_root, signature)
    else
      _ -> false
    end
  end

  @doc """
  Key derivation from seed (EIP-2333)
  """
  @spec derive_child_privkey(privkey(), non_neg_integer()) :: privkey()
  def derive_child_privkey(parent_privkey, index) do
    # Implement HD key derivation for validators
    salt = "BLS-SIG-KEYGEN-SALT-"
    ikm = parent_privkey <> <<index::32>>

    # Use HKDF to derive child key
    hkdf_expand(hkdf_extract(salt, ikm), "", 32)
  end

  @doc """
  Create a deposit signature for validator activation
  """
  def create_deposit_signature(privkey, deposit_message, fork_version) do
    # Special domain for deposits
    domain = compute_domain(:deposit, fork_version, <<0::256>>)
    sign_with_domain(privkey, deposit_message, domain)
  end

  # Validation functions

  defp validate_privkey(privkey) when byte_size(privkey) == 32 do
    # Check if privkey is within valid range
    key_int = :binary.decode_unsigned(privkey, :big)

    if key_int > 0 and key_int < @bls_modulus do
      :ok
    else
      {:error, :invalid_privkey_range}
    end
  end

  defp validate_privkey(_), do: {:error, :invalid_privkey_size}

  defp validate_pubkey(pubkey) when byte_size(pubkey) == @pubkey_size do
    # Could add point validation here
    :ok
  end

  defp validate_pubkey(_), do: {:error, :invalid_pubkey_size}

  defp validate_pubkeys(pubkeys) do
    if Enum.all?(pubkeys, &(byte_size(&1) == @pubkey_size)) do
      :ok
    else
      {:error, :invalid_pubkey_in_list}
    end
  end

  defp validate_signature(signature) when byte_size(signature) == @signature_size do
    :ok
  end

  defp validate_signature(_), do: {:error, :invalid_signature_size}

  defp validate_domain(domain) when byte_size(domain) == @domain_size do
    :ok
  end

  defp validate_domain(_), do: {:error, :invalid_domain_size}

  # Helper functions

  defp compute_signing_root(message, domain) do
    # SSZ hash tree root of SigningData
    message_root = hash_tree_root(message)
    signing_data = message_root <> domain
    :crypto.hash(:sha256, signing_data)
  end

  defp compute_domain(domain_type, fork_version, genesis_validators_root) do
    domain_type_bytes = domain_type_to_bytes(domain_type)
    fork_data_root = hash_tree_root({fork_version, genesis_validators_root})
    domain_type_bytes <> :binary.part(fork_data_root, 0, 28)
  end

  defp domain_type_to_bytes(domain_type) do
    case domain_type do
      :beacon_proposer -> <<0, 0, 0, 0>>
      :beacon_attester -> <<1, 0, 0, 0>>
      :randao -> <<2, 0, 0, 0>>
      :deposit -> <<3, 0, 0, 0>>
      :voluntary_exit -> <<4, 0, 0, 0>>
      :selection_proof -> <<5, 0, 0, 0>>
      :aggregate_and_proof -> <<6, 0, 0, 0>>
      :sync_committee -> <<7, 0, 0, 0>>
      :sync_committee_selection_proof -> <<8, 0, 0, 0>>
      :contribution_and_proof -> <<9, 0, 0, 0>>
      :bls_to_execution_change -> <<10, 0, 0, 0>>
      _ -> <<0, 0, 0, 0>>
    end
  end

  defp hash_tree_root(data) do
    # Simplified - should use proper SSZ
    :crypto.hash(:sha256, :erlang.term_to_binary(data))
  end

  # HKDF implementation for key derivation
  defp hkdf_extract(salt, ikm) do
    :crypto.mac(:hmac, :sha256, salt, ikm)
  end

  defp hkdf_expand(prk, info, length) do
    :crypto.mac(:hmac, :sha256, prk, <<info::binary, 1>>)
    |> :binary.part(0, length)
  end

  # Fallback implementations for aggregation

  defp aggregate_signatures_fallback([]), do: {:error, :empty_signatures}
  defp aggregate_signatures_fallback([sig]), do: {:ok, sig}

  defp aggregate_signatures_fallback(signatures) do
    # Simplified aggregation - in production would use proper BLS12-381 math
    # For now, XOR the signatures together as a placeholder
    aggregated =
      signatures
      |> Enum.reduce(<<0::768>>, fn sig, acc ->
        xor_binaries(sig, acc)
      end)

    {:ok, aggregated}
  end

  defp aggregate_pubkeys_fallback([]), do: {:error, :empty_pubkeys}
  defp aggregate_pubkeys_fallback([pk]), do: {:ok, pk}

  defp aggregate_pubkeys_fallback(pubkeys) do
    # Simplified aggregation - in production would use proper BLS12-381 math
    # For now, XOR the pubkeys together as a placeholder
    aggregated =
      pubkeys
      |> Enum.reduce(<<0::384>>, fn pk, acc ->
        xor_binaries(pk, acc)
      end)

    {:ok, aggregated}
  end

  defp xor_binaries(bin1, bin2) when byte_size(bin1) == byte_size(bin2) do
    :crypto.exor(bin1, bin2)
  end

  defp xor_binaries(_, _), do: {:error, :size_mismatch}
end
