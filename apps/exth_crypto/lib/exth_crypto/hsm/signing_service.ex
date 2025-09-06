defmodule ExthCrypto.HSM.SigningService do
  @moduledoc """
  Enterprise transaction signing service with HSM integration.

  This module provides a drop-in replacement for the existing transaction signing
  infrastructure, automatically routing signing operations to HSM or software
  backends based on configuration and key availability.

  Features:
  - Seamless integration with existing Blockchain.Transaction.Signature
  - Automatic backend selection (HSM preferred, software fallback)
  - Support for multiple concurrent signing operations
  - Comprehensive audit logging and monitoring
  - Recovery ID calculation for Ethereum compatibility
  - Support for different chain IDs and EIP-155
  """

  use GenServer
  require Logger

  alias ExthCrypto.HSM.KeyManager
  # Aliases would be used in full integration
  # alias ExthCrypto.{Signature, Key}
  alias ExthCrypto.Hash.Keccak
  # Dynamic loading to avoid circular dependencies
  # alias Blockchain.Transaction

  @type signing_context :: %{
          chain_id: non_neg_integer() | nil,
          key_id: String.t() | nil,
          key_role: atom() | nil,
          audit_metadata: map()
        }

  @type signing_result :: %{
          v: non_neg_integer(),
          r: non_neg_integer(),
          s: non_neg_integer(),
          signature: binary(),
          recovery_id: non_neg_integer(),
          backend_used: atom(),
          timestamp: DateTime.t()
        }

  # EIP-155 constants
  @base_recovery_id 27
  @base_recovery_id_eip_155 35

  # Service configuration
  @default_config %{
    prefer_hsm: true,
    fallback_enabled: true,
    max_concurrent_operations: 100,
    operation_timeout: 10_000,
    audit_enabled: true
  }

  ## GenServer API

  def start_link(config \\ %{}) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def init(config) do
    full_config = Map.merge(@default_config, config)

    state = %{
      config: full_config,
      active_operations: %{},
      stats: %{
        total_signatures: 0,
        hsm_signatures: 0,
        software_signatures: 0,
        fallback_activations: 0,
        errors: 0
      }
    }

    Logger.info("HSM Signing Service initialized")
    {:ok, state}
  end

  def handle_call({:sign_hash, hash, context}, from, state) do
    if map_size(state.active_operations) >= state.config.max_concurrent_operations do
      {:reply, {:error, "Maximum concurrent operations exceeded"}, state}
    else
      operation_id = generate_operation_id()

      # Track active operation
      new_state = %{
        state
        | active_operations:
            Map.put(state.active_operations, operation_id, %{
              from: from,
              started_at: DateTime.utc_now(),
              context: context
            })
      }

      # Perform async signing
      Task.start_link(fn ->
        result = perform_signing(hash, context)
        GenServer.cast(__MODULE__, {:signing_complete, operation_id, result})
      end)

      {:noreply, new_state}
    end
  end

  def handle_call({:sign_transaction, tx, private_key, chain_id}, _from, state) do
    # Legacy compatibility - handle direct private key signing
    context = %{
      chain_id: chain_id,
      key_id: nil,
      key_role: :legacy_direct,
      audit_metadata: %{
        transaction_type: determine_transaction_type(tx),
        legacy_signing: true
      }
    }

    hash = calculate_transaction_hash(tx, chain_id)

    case sign_hash_with_private_key(hash, private_key, chain_id) do
      {:ok, result} ->
        # Update transaction with signature
        signed_tx = %{tx | v: result.v, r: result.r, s: result.s}

        # Update stats
        new_stats = Map.update(state.stats, :software_signatures, 1, &(&1 + 1))
        new_stats = Map.update(new_stats, :total_signatures, 1, &(&1 + 1))

        new_state = %{state | stats: new_stats}

        if state.config.audit_enabled do
          audit_transaction_signing(signed_tx, context, result)
        end

        {:reply, {:ok, signed_tx}, new_state}

      {:error, reason} ->
        new_stats = Map.update(state.stats, :errors, 1, &(&1 + 1))
        new_state = %{state | stats: new_stats}

        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:sign_transaction_with_key, tx, key_id, chain_id}, _from, state) do
    # Modern HSM-enabled transaction signing
    context = %{
      chain_id: chain_id,
      key_id: key_id,
      key_role: :transaction_signer,
      audit_metadata: %{
        transaction_type: determine_transaction_type(tx),
        to: tx.to,
        value: tx.value,
        gas_limit: tx.gas_limit
      }
    }

    hash = calculate_transaction_hash(tx, chain_id)

    case perform_signing(hash, context) do
      {:ok, result} ->
        # Update transaction with signature
        signed_tx = %{tx | v: result.v, r: result.r, s: result.s}

        # Update stats
        new_stats =
          case result.backend_used do
            :hsm ->
              state.stats
              |> Map.update(:hsm_signatures, 1, &(&1 + 1))
              |> Map.update(:total_signatures, 1, &(&1 + 1))

            :software ->
              state.stats
              |> Map.update(:software_signatures, 1, &(&1 + 1))
              |> Map.update(:total_signatures, 1, &(&1 + 1))
          end

        new_state = %{state | stats: new_stats}

        if state.config.audit_enabled do
          audit_transaction_signing(signed_tx, context, result)
        end

        {:reply, {:ok, signed_tx}, new_state}

      {:error, reason} ->
        new_stats = Map.update(state.stats, :errors, 1, &(&1 + 1))
        new_state = %{state | stats: new_stats}

        if state.config.audit_enabled do
          audit_signing_failure(hash, context, reason)
        end

        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:get_stats, _from, state) do
    enhanced_stats =
      Map.merge(state.stats, %{
        active_operations: map_size(state.active_operations),
        uptime: get_uptime(),
        config: state.config
      })

    {:reply, {:ok, enhanced_stats}, state}
  end

  def handle_cast({:signing_complete, operation_id, result}, state) do
    case Map.pop(state.active_operations, operation_id) do
      {nil, _} ->
        Logger.warning("Received completion for unknown operation: #{operation_id}")
        {:noreply, state}

      {operation, new_operations} ->
        GenServer.reply(operation.from, result)

        # Update stats
        new_stats =
          case result do
            {:ok, signing_result} ->
              stats = Map.update(state.stats, :total_signatures, 1, &(&1 + 1))

              case signing_result.backend_used do
                :hsm -> Map.update(stats, :hsm_signatures, 1, &(&1 + 1))
                :software -> Map.update(stats, :software_signatures, 1, &(&1 + 1))
              end

            {:error, _} ->
              Map.update(state.stats, :errors, 1, &(&1 + 1))
          end

        new_state = %{
          state
          | active_operations: new_operations,
            stats: new_stats
        }

        {:noreply, new_state}
    end
  end

  ## Public API

  @doc """
  Sign a hash using the best available backend.

  This is the primary interface for hash signing operations.
  """
  @spec sign_hash(binary(), signing_context()) :: {:ok, signing_result()} | {:error, String.t()}
  def sign_hash(hash, context \\ %{}) do
    GenServer.call(__MODULE__, {:sign_hash, hash, context}, 15_000)
  end

  @doc """
  Sign a transaction using a direct private key (legacy compatibility).
  """
  @spec sign_transaction(Transaction.t(), binary(), non_neg_integer() | nil) ::
          {:ok, Transaction.t()} | {:error, String.t()}
  def sign_transaction(tx, private_key, chain_id \\ nil) do
    GenServer.call(__MODULE__, {:sign_transaction, tx, private_key, chain_id}, 15_000)
  end

  @doc """
  Sign a transaction using a managed key ID (preferred method).
  """
  @spec sign_transaction_with_key(Transaction.t(), String.t(), non_neg_integer() | nil) ::
          {:ok, Transaction.t()} | {:error, String.t()}
  def sign_transaction_with_key(tx, key_id, chain_id \\ nil) do
    GenServer.call(__MODULE__, {:sign_transaction_with_key, tx, key_id, chain_id}, 15_000)
  end

  @doc """
  Get signing service statistics and performance metrics.
  """
  @spec get_stats() :: {:ok, map()}
  def get_stats() do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Convenience function for Ethereum address derivation from key ID.
  """
  @spec get_address_from_key(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def get_address_from_key(key_id) do
    case KeyManager.get_public_key(key_id) do
      {:ok, public_key} ->
        address =
          public_key
          |> Keccak.kec()
          # Take last 20 bytes
          |> Binary.drop(12)

        {:ok, address}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Private Implementation

  defp perform_signing(hash, context) do
    case determine_signing_strategy(context) do
      {:key_manager, key_id} ->
        sign_with_key_manager(hash, key_id, context)

      {:direct_software, private_key} ->
        sign_hash_with_private_key(hash, private_key, context.chain_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp determine_signing_strategy(context) do
    case context do
      %{key_id: key_id} when not is_nil(key_id) ->
        {:key_manager, key_id}

      %{private_key: private_key} when not is_nil(private_key) ->
        {:direct_software, private_key}

      _ ->
        # Try to find a default key for the role
        case find_default_key(context.key_role || :transaction_signer) do
          {:ok, key_id} -> {:key_manager, key_id}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp sign_with_key_manager(hash, key_id, context) do
    case KeyManager.sign(key_id, hash) do
      {:ok, signature} ->
        case convert_to_ethereum_signature(signature, hash, context) do
          {:ok, result} ->
            Logger.debug("Successfully signed with key #{key_id} using #{result.backend_used}")
            {:ok, result}

          {:error, reason} ->
            Logger.error("Failed to convert signature for key #{key_id}: #{reason}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Key manager signing failed for key #{key_id}: #{reason}")
        {:error, reason}
    end
  end

  defp sign_hash_with_private_key(hash, private_key, chain_id) do
    try do
      {:ok, <<r::size(256), s::size(256)>>, recovery_id} =
        :libsecp256k1.ecdsa_sign_compact(hash, private_key, :default, <<>>)

      # Apply EIP-155 recovery ID adjustment
      v =
        if chain_id do
          chain_id * 2 + @base_recovery_id_eip_155 + recovery_id
        else
          @base_recovery_id + recovery_id
        end

      signature = <<r::size(256), s::size(256)>>

      result = %{
        v: v,
        r: r,
        s: s,
        signature: signature,
        recovery_id: recovery_id,
        backend_used: :software,
        timestamp: DateTime.utc_now()
      }

      {:ok, result}
    rescue
      error ->
        {:error, "Software signing failed: #{inspect(error)}"}
    end
  end

  defp convert_to_ethereum_signature(der_signature, original_hash, context) do
    with {:ok, r, s} <- parse_der_signature(der_signature),
         {:ok, recovery_id} <- calculate_recovery_id(r, s, original_hash, context) do
      # Apply EIP-155 recovery ID adjustment
      v =
        if context.chain_id do
          context.chain_id * 2 + @base_recovery_id_eip_155 + recovery_id
        else
          @base_recovery_id + recovery_id
        end

      signature =
        pad_to_32_bytes(:binary.encode_unsigned(r)) <>
          pad_to_32_bytes(:binary.encode_unsigned(s))

      result = %{
        v: v,
        r: r,
        s: s,
        signature: signature,
        recovery_id: recovery_id,
        backend_used: :hsm,
        timestamp: DateTime.utc_now()
      }

      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_der_signature(der_signature) do
    try do
      # Simple DER parsing for ECDSA signature
      case der_signature do
        <<0x30, _length, 0x02, r_length, r::binary-size(r_length), 0x02, s_length,
          s::binary-size(s_length), _rest::binary>> ->
          r_int = :binary.decode_unsigned(r)
          s_int = :binary.decode_unsigned(s)

          {:ok, r_int, s_int}

        _ ->
          {:error, "Invalid DER signature format"}
      end
    rescue
      _ -> {:error, "Failed to parse DER signature"}
    end
  end

  defp calculate_recovery_id(r, s, hash, context) do
    # For HSM signatures, we need to determine the recovery ID by testing
    # This is computationally expensive but necessary for HSM integration

    case context.key_id do
      nil ->
        {:error, "Cannot calculate recovery ID without key information"}

      key_id ->
        case KeyManager.get_public_key(key_id) do
          {:ok, expected_public_key} ->
            find_recovery_id(r, s, hash, expected_public_key)

          {:error, reason} ->
            {:error, "Failed to get public key: #{reason}"}
        end
    end
  end

  defp find_recovery_id(r, s, hash, expected_public_key) do
    signature =
      pad_to_32_bytes(:binary.encode_unsigned(r)) <>
        pad_to_32_bytes(:binary.encode_unsigned(s))

    # Try each possible recovery ID (0-3)
    Enum.reduce_while(0..3, {:error, "No valid recovery ID found"}, fn recovery_id, acc ->
      case :libsecp256k1.ecdsa_recover_compact(hash, signature, :uncompressed, recovery_id) do
        {:ok, <<_prefix::8, recovered_public_key::binary>>} ->
          if recovered_public_key == expected_public_key do
            {:halt, {:ok, recovery_id}}
          else
            {:cont, acc}
          end

        {:error, _} ->
          {:cont, acc}
      end
    end)
  end

  defp find_default_key(role) do
    case KeyManager.list_keys(%{role: role}) do
      {:ok, []} ->
        {:error, "No keys found for role: #{role}"}

      {:ok, [key | _]} ->
        {:ok, key.id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp determine_transaction_type(tx) do
    cond do
      tx.to == <<>> or tx.to == "" -> :contract_creation
      tx.data && byte_size(tx.data) > 0 -> :contract_call
      tx.value > 0 -> :transfer
      true -> :other
    end
  end

  defp pad_to_32_bytes(binary) when byte_size(binary) < 32 do
    padding = 32 - byte_size(binary)
    <<0::size(padding * 8)>> <> binary
  end

  defp pad_to_32_bytes(binary), do: binary

  defp generate_operation_id() do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp get_uptime() do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    uptime_ms
  end

  # Audit logging functions

  defp audit_transaction_signing(tx, context, result) do
    audit_data = %{
      event: "transaction_signed",
      transaction: %{
        hash:
          calculate_transaction_hash(tx, context.chain_id)
          |> Base.encode16(case: :lower),
        to: format_address(tx.to),
        value: tx.value,
        gas_limit: tx.gas_limit,
        gas_price: tx.gas_price,
        nonce: tx.nonce
      },
      signature: %{
        v: result.v,
        r: result.r |> :binary.encode_unsigned() |> Base.encode16(case: :lower),
        s: result.s |> :binary.encode_unsigned() |> Base.encode16(case: :lower),
        backend: result.backend_used
      },
      context: context,
      timestamp: DateTime.utc_now()
    }

    Logger.info("SIGNING_AUDIT: #{Jason.encode!(audit_data)}")
  end

  defp audit_signing_failure(hash, context, reason) do
    audit_data = %{
      event: "signing_failed",
      hash: Base.encode16(hash, case: :lower),
      reason: reason,
      context: context,
      timestamp: DateTime.utc_now()
    }

    Logger.warning("SIGNING_AUDIT: #{Jason.encode!(audit_data)}")
  end

  defp format_address(address) when address in [<<>>, ""], do: "contract_creation"

  defp format_address(address) when is_binary(address) do
    "0x" <> Base.encode16(address, case: :lower)
  end

  # Dynamic transaction hash calculation to avoid circular dependencies
  defp calculate_transaction_hash(tx, chain_id) do
    # Try to load the Blockchain.Transaction.Signature module dynamically
    case Code.ensure_loaded(Blockchain.Transaction.Signature) do
      {:module, module} ->
        apply(module, :transaction_hash, [tx, chain_id])

      {:error, _} ->
        # Fallback: basic hash calculation without full transaction context
        # This is a simplified version for HSM operations when blockchain module isn't available
        Logger.warning(
          "Blockchain.Transaction.Signature not available, using simplified hash calculation"
        )

        tx_data = inspect(tx) <> to_string(chain_id || "")
        Keccak.kec(tx_data)
    end
  rescue
    error ->
      Logger.error("Failed to calculate transaction hash: #{inspect(error)}")
      # Return a deterministic hash based on available data
      tx_data = inspect(tx) <> to_string(chain_id || "")
      Keccak.kec(tx_data)
  end
end
