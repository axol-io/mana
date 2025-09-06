defmodule Blockchain.Transaction.HSMSignature do
  @moduledoc """
  HSM-enabled transaction signing module.

  This module provides a drop-in replacement for Blockchain.Transaction.Signature
  that transparently uses HSM when available, with automatic fallback to software
  signing when HSM is not configured or available.

  Usage:
  1. For existing code: Replace calls to Blockchain.Transaction.Signature with
     Blockchain.Transaction.HSMSignature - all functions are compatible.

  2. For new HSM-enabled code: Use the new *_with_key functions that accept
     key IDs instead of raw private keys.

  This maintains 100% backward compatibility while adding HSM support.
  """

  alias Blockchain.Transaction
  alias Blockchain.Transaction.Signature
  alias ExthCrypto.HSM.{SigningService, KeyManager, ConfigManager}
  alias ExthCrypto.Hash.Keccak

  require Logger

  @type public_key :: <<_::512>>
  @type private_key :: <<_::256>>
  @type recovery_id :: <<_::8>>
  @type hash_v :: integer()
  @type hash_r :: integer()
  @type hash_s :: integer()
  @type key_id :: String.t()

  # Re-export constants from original signature module
  def secp256k1n, do: Signature.secp256k1n()
  def secp256k1n_2, do: Signature.secp256k1n_2()

  ## Drop-in replacement functions (backward compatibility)

  @doc """
  Given a private key, returns a public key.

  This function maintains compatibility with the original while supporting HSM keys.
  """
  @spec get_public_key(private_key | key_id) :: {:ok, public_key} | {:error, String.t()}
  def get_public_key(<<_::256>> = private_key) do
    # This is a raw private key - use original implementation
    Signature.get_public_key(private_key)
  end

  def get_public_key(key_id) when is_binary(key_id) do
    # This looks like a key ID - try HSM first
    case hsm_available?() do
      true ->
        case KeyManager.get_public_key(key_id) do
          {:ok, public_key} -> {:ok, public_key}
          {:error, _} -> {:error, "Key not found in HSM: #{key_id}"}
        end

      false ->
        {:error, "HSM not available for key: #{key_id}"}
    end
  end

  @doc """
  Returns a ECDSA signature (v,r,s) for a given hashed value.

  Maintains compatibility with original implementation.
  """
  @spec sign_hash(Keccak.keccak_hash(), private_key | key_id, integer() | nil) ::
          {hash_v, hash_r, hash_s}
  def sign_hash(hash, key, chain_id \\ nil)
  def sign_hash(hash, <<_::256>> = private_key, chain_id) do
    # Raw private key - use enhanced signing service for consistency
    case hsm_available?() do
      true ->
        context = %{
          chain_id: chain_id,
          key_id: nil,
          private_key: private_key,
          key_role: :legacy_direct,
          audit_metadata: %{
            operation: :sign_hash,
            legacy_mode: true
          }
        }

        case SigningService.sign_hash(hash, context) do
          {:ok, result} ->
            {result.v, result.r, result.s}

          {:error, _reason} ->
            # Fallback to original implementation
            Logger.warning("HSM signing failed, falling back to software")
            Signature.sign_hash(hash, private_key, chain_id)
        end

      false ->
        # HSM not available - use original implementation
        Signature.sign_hash(hash, private_key, chain_id)
    end
  end

  def sign_hash(hash, key_id, chain_id) when is_binary(key_id) do
    # Key ID provided - must use HSM
    case hsm_available?() do
      true ->
        context = %{
          chain_id: chain_id,
          key_id: key_id,
          key_role: :transaction_signer,
          audit_metadata: %{
            operation: :sign_hash,
            key_id: key_id
          }
        }

        case SigningService.sign_hash(hash, context) do
          {:ok, result} ->
            {result.v, result.r, result.s}

          {:error, reason} ->
            Logger.error("HSM signing failed for key #{key_id}: #{reason}")
            throw({:hsm_signing_error, reason})
        end

      false ->
        Logger.error("HSM not available but key ID provided: #{key_id}")
        throw({:hsm_not_available, key_id})
    end
  end

  @doc """
  Recovers a public key from a signed hash.

  Maintains full compatibility with original implementation.
  """
  @spec recover_public(Keccak.keccak_hash(), hash_v, hash_r, hash_s, integer() | nil) ::
          {:ok, public_key} | {:error, String.t()}
  def recover_public(hash, v, r, s, chain_id \\ nil) do
    # Recovery is the same regardless of signing backend
    Signature.recover_public(hash, v, r, s, chain_id)
  end

  @doc """
  Verifies a given signature is valid.

  Maintains full compatibility with original implementation.
  """
  @spec is_signature_valid?(integer(), integer(), integer(), integer(), max_s: atom()) ::
          boolean()
  def is_signature_valid?(r, s, v, chain_id, opts) do
    # Signature validation is the same regardless of signing backend
    Signature.is_signature_valid?(r, s, v, chain_id, opts)
  end

  @doc """
  Returns a hash of a given transaction.

  Maintains full compatibility with original implementation.
  """
  @spec transaction_hash(Transaction.t(), integer() | nil) :: Keccak.keccak_hash()
  def transaction_hash(tx, chain_id \\ nil) do
    # Transaction hashing is the same regardless of signing backend
    Signature.transaction_hash(tx, chain_id)
  end

  @doc """
  Takes a given transaction and returns a version signed with the given private key.

  Enhanced to support both private keys and key IDs.
  """
  @spec sign_transaction(Transaction.t(), private_key | key_id, non_neg_integer() | nil) ::
          Transaction.t()
  def sign_transaction(tx, key, chain_id \\ nil)
  def sign_transaction(tx, <<_::256>> = private_key, chain_id) do
    # Raw private key - use enhanced signing service
    case hsm_available?() do
      true ->
        case SigningService.sign_transaction(tx, private_key, chain_id) do
          {:ok, signed_tx} ->
            signed_tx

          {:error, reason} ->
            Logger.warning("HSM transaction signing failed, falling back to software: #{reason}")
            Signature.sign_transaction(tx, private_key, chain_id)
        end

      false ->
        # Use original implementation
        Signature.sign_transaction(tx, private_key, chain_id)
    end
  end

  def sign_transaction(tx, key_id, chain_id) when is_binary(key_id) do
    # Key ID provided - must use HSM
    case hsm_available?() do
      true ->
        case SigningService.sign_transaction_with_key(tx, key_id, chain_id) do
          {:ok, signed_tx} ->
            signed_tx

          {:error, reason} ->
            Logger.error("HSM transaction signing failed for key #{key_id}: #{reason}")
            throw({:hsm_signing_error, reason, key_id})
        end

      false ->
        Logger.error("HSM not available but key ID provided: #{key_id}")
        throw({:hsm_not_available, key_id})
    end
  end

  @doc """
  Given a private key or key ID, this will return an associated ethereum address.
  """
  @spec address_from_private(private_key | key_id) :: EVM.address()
  def address_from_private(<<_::256>> = private_key) do
    # Use original implementation for raw private keys
    Signature.address_from_private(private_key)
  end

  def address_from_private(key_id) when is_binary(key_id) do
    # Key ID - get address through HSM
    case SigningService.get_address_from_key(key_id) do
      {:ok, address} ->
        address

      {:error, reason} ->
        Logger.error("Failed to get address for key #{key_id}: #{reason}")
        throw({:address_derivation_failed, key_id, reason})
    end
  end

  @doc """
  Given a public key, this will return an associated ethereum address.

  Maintains full compatibility with original implementation.
  """
  @spec address_from_public(public_key) :: EVM.address()
  def address_from_public(public_key) do
    # Address derivation is the same regardless of key source
    Signature.address_from_public(public_key)
  end

  @doc """
  Given a transaction, we will determine the sender of the message.

  Maintains full compatibility with original implementation.
  """
  @spec sender(Transaction.t(), integer() | nil) :: {:ok, EVM.address()} | {:error, String.t()}
  def sender(tx, chain_id \\ nil) do
    # Sender recovery is the same regardless of signing backend
    Signature.sender(tx, chain_id)
  end

  ## New HSM-specific functions

  @doc """
  Generate a new HSM-backed key for Ethereum transactions.
  """
  @spec generate_hsm_key(String.t(), atom()) :: {:ok, key_id} | {:error, String.t()}
  def generate_hsm_key(label, role \\ :transaction_signer) do
    case hsm_available?() do
      true ->
        params = %{
          backend: :hsm,
          label: label,
          role: role,
          usage: [:signing]
        }

        case KeyManager.generate_key(params) do
          {:ok, key_descriptor} -> {:ok, key_descriptor.id}
          {:error, reason} -> {:error, reason}
        end

      false ->
        {:error, "HSM not available"}
    end
  end

  @doc """
  List available HSM keys with optional filtering.
  """
  @spec list_hsm_keys(map()) :: {:ok, [map()]} | {:error, String.t()}
  def list_hsm_keys(filters \\ %{}) do
    case hsm_available?() do
      true ->
        KeyManager.list_keys(filters)

      false ->
        {:error, "HSM not available"}
    end
  end

  @doc """
  Get detailed information about an HSM key.
  """
  @spec get_key_info(key_id) :: {:ok, map()} | {:error, String.t()}
  def get_key_info(key_id) do
    case hsm_available?() do
      true ->
        KeyManager.get_key(key_id)

      false ->
        {:error, "HSM not available"}
    end
  end

  @doc """
  Get HSM system status and statistics.
  """
  @spec get_hsm_status() :: {:ok, map()} | {:error, String.t()}
  def get_hsm_status() do
    case hsm_available?() do
      true ->
        with {:ok, signing_stats} <- SigningService.get_stats(),
             {:ok, key_stats} <- KeyManager.get_stats() do
          {:ok,
           %{
             hsm_enabled: true,
             signing_service: signing_stats,
             key_manager: key_stats,
             timestamp: DateTime.utc_now()
           }}
        else
          {:error, reason} -> {:error, reason}
        end

      false ->
        {:ok,
         %{
           hsm_enabled: false,
           reason: "HSM not configured or not available",
           timestamp: DateTime.utc_now()
         }}
    end
  end

  @doc """
  Sign a transaction using the default key for a given role.
  """
  @spec sign_transaction_with_role(Transaction.t(), atom(), non_neg_integer() | nil) ::
          {:ok, Transaction.t()} | {:error, String.t()}
  def sign_transaction_with_role(tx, role, chain_id \\ nil) do
    case hsm_available?() do
      true ->
        # Find a key with the specified role
        case KeyManager.list_keys(%{role: role}) do
          {:ok, []} ->
            {:error, "No keys found for role: #{role}"}

          {:ok, [key | _]} ->
            case SigningService.sign_transaction_with_key(tx, key.id, chain_id) do
              {:ok, signed_tx} -> {:ok, signed_tx}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      false ->
        {:error, "HSM not available"}
    end
  end

  @doc """
  Batch sign multiple transactions using HSM for efficiency.
  """
  @spec batch_sign_transactions([Transaction.t()], key_id, non_neg_integer() | nil) ::
          {:ok, [Transaction.t()]} | {:error, String.t()}
  def batch_sign_transactions(transactions, key_id, chain_id \\ nil) do
    case hsm_available?() do
      true ->
        # Sign each transaction - could be optimized for true batch operations
        results =
          Enum.map(transactions, fn tx ->
            case SigningService.sign_transaction_with_key(tx, key_id, chain_id) do
              {:ok, signed_tx} -> signed_tx
              {:error, reason} -> {:error, reason}
            end
          end)

        # Check if any failed
        case Enum.find(results, fn result -> match?({:error, _}, result) end) do
          nil -> {:ok, results}
          {:error, reason} -> {:error, "Batch signing failed: #{reason}"}
        end

      false ->
        {:error, "HSM not available"}
    end
  end

  ## Private helper functions

  defp hsm_available?() do
    case ConfigManager.hsm_enabled?() do
      true ->
        # Check if all required HSM services are running
        try do
          case Process.whereis(SigningService) do
            pid when is_pid(pid) -> Process.alive?(pid)
            nil -> false
          end
        rescue
          _ -> false
        end

      false ->
        false
    end
  end

  ## Migration helpers

  @doc """
  Helper function to migrate from raw private key to HSM key.

  This function imports a private key into the HSM (if supported) and returns
  the HSM key ID. Use this for migrating existing keys to HSM.
  """
  @spec migrate_private_key_to_hsm(private_key, String.t(), atom()) ::
          {:ok, key_id} | {:error, String.t()}
  def migrate_private_key_to_hsm(_private_key, label, role \\ :transaction_signer) do
    case hsm_available?() do
      true ->
        # Most HSMs don't allow key import for security reasons
        # Instead, we generate a new HSM key and return instructions
        case generate_hsm_key(label, role) do
          {:ok, key_id} ->
            Logger.warning(
              "HSM key generated. Original private key cannot be imported for security reasons."
            )

            Logger.warning(
              "You will need to manually update any addresses/accounts to use the new HSM key."
            )

            Logger.warning("New HSM key ID: #{key_id}")
            {:ok, key_id}

          {:error, reason} ->
            {:error, reason}
        end

      false ->
        {:error, "HSM not available"}
    end
  end

  @doc """
  Helper to check if a value is a private key or key ID.
  """
  @spec is_private_key?(any()) :: boolean()
  def is_private_key?(<<_::256>>), do: true
  def is_private_key?(_), do: false

  @doc """
  Helper to check if a value is likely a key ID.
  """
  @spec is_key_id?(any()) :: boolean()
  def is_key_id?(value) when is_binary(value) do
    # Key IDs are typically hex strings of specific length
    String.length(value) == 16 and String.match?(value, ~r/^[a-fA-F0-9]+$/)
  end

  def is_key_id?(_), do: false
end
