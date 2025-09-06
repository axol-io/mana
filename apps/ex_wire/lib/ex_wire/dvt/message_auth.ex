defmodule ExWire.DVT.MessageAuth do
  @moduledoc """
  DVT Message Authentication and Replay Protection System.
  
  Provides cryptographic authentication for DVT messages with:
  - Ed25519 signature-based message authentication
  - Time-window based replay protection
  - Message sequence validation
  - Cryptographic nonce management
  """

  require Logger
  
  alias ExWire.Enterprise.AuditLogger
  alias ExWire.DVT.KeyManager

  @type message_id :: String.t()
  @type signature :: binary()
  @type nonce :: binary()
  @type timestamp :: DateTime.t()
  
  # Message authentication context
  @type auth_context :: %{
    sender_id: pos_integer(),
    cluster_id: String.t(),
    message_type: atom(),
    sequence: pos_integer(),
    timestamp: DateTime.t(),
    nonce: nonce(),
    payload_hash: binary()
  }

  # Authentication configuration
  @replay_window_seconds 300  # 5 minutes
  @max_clock_skew_seconds 30  # 30 seconds  
  @nonce_size 16             # 16 bytes
  @sequence_gap_threshold 100 # Maximum sequence number gap

  ## Public API

  @doc """
  Create an authenticated message with signature and replay protection.
  """
  @spec create_authenticated_message(
    cluster_id :: String.t(),
    message_type :: atom(),
    payload :: binary(),
    private_key :: binary(),
    sender_id :: pos_integer()
  ) :: {:ok, map()} | {:error, atom()}
  def create_authenticated_message(cluster_id, message_type, payload, private_key, sender_id) do
    try do
      sequence = get_next_sequence(sender_id, cluster_id)
      nonce = generate_nonce()
      timestamp = DateTime.utc_now()
      payload_hash = hash_payload(payload)
      
      auth_context = %{
        sender_id: sender_id,
        cluster_id: cluster_id,
        message_type: message_type,
        sequence: sequence,
        timestamp: timestamp,
        nonce: nonce,
        payload_hash: payload_hash
      }
      
      case sign_message_context(auth_context, private_key) do
        {:ok, signature} ->
          message = %{
            cluster_id: cluster_id,
            sender_id: sender_id,
            message_type: message_type,
            sequence: sequence,
            timestamp: timestamp,
            nonce: nonce,
            payload: payload,
            signature: signature,
            auth_version: "1.0"
          }
          
          # Store sequence number
          store_sequence(sender_id, cluster_id, sequence)
          
          {:ok, message}
          
        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error ->
        Logger.error("Failed to create authenticated message: #{inspect(error)}")
        {:error, :authentication_failed}
    end
  end

  @doc """
  Verify an authenticated message and check for replay attacks.
  """
  @spec verify_authenticated_message(map()) :: 
    {:ok, :valid} | {:error, :invalid_signature | :replay_attack | :expired | :invalid_sequence}
  def verify_authenticated_message(message) do
    with :ok <- validate_message_structure(message),
         :ok <- check_timestamp_validity(message.timestamp),
         {:ok, public_key} <- get_sender_public_key(message.sender_id, message.cluster_id),
         :ok <- verify_signature(message, public_key),
         :ok <- check_replay_protection(message),
         :ok <- validate_sequence_number(message) do
      
      # Record successful verification
      record_verified_message(message)
      
      AuditLogger.log(:debug, "DVT message authenticated", %{
        sender_id: message.sender_id,
        cluster_id: message.cluster_id,
        sequence: message.sequence
      })
      
      {:ok, :valid}
    else
      {:error, reason} = error ->
        AuditLogger.log(:warning, "DVT message authentication failed", %{
          sender_id: Map.get(message, :sender_id),
          cluster_id: Map.get(message, :cluster_id),
          reason: reason
        })
        error
    end
  end

  @doc """
  Clean up expired authentication state and replay protection data.
  """
  @spec cleanup_expired_data() :: :ok
  def cleanup_expired_data() do
    cutoff = DateTime.add(DateTime.utc_now(), -@replay_window_seconds, :second)
    
    # Clean up message cache
    cleanup_message_cache(cutoff)
    
    # Clean up sequence tracking
    cleanup_sequence_tracking(cutoff)
    
    Logger.debug("DVT authentication data cleanup completed")
    :ok
  end

  @doc """
  Get authentication statistics for monitoring.
  """
  @spec get_auth_statistics() :: map()
  def get_auth_statistics() do
    %{
      total_messages_authenticated: get_total_authenticated(),
      authentication_failures: get_authentication_failures(),
      replay_attempts: get_replay_attempts(),
      active_sequences: get_active_sequences(),
      cache_size: get_cache_size(),
      last_cleanup: get_last_cleanup()
    }
  end

  ## Private Functions

  defp validate_message_structure(message) do
    required_fields = [:cluster_id, :sender_id, :message_type, :sequence, :timestamp, :nonce, :payload, :signature]
    
    case Enum.all?(required_fields, &Map.has_key?(message, &1)) do
      true -> :ok
      false -> {:error, :invalid_structure}
    end
  end

  defp check_timestamp_validity(timestamp) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, timestamp, :second)
    
    cond do
      diff_seconds > @replay_window_seconds ->
        {:error, :expired}
      diff_seconds < -@max_clock_skew_seconds ->
        {:error, :future_timestamp}
      true ->
        :ok
    end
  end

  defp get_sender_public_key(sender_id, cluster_id) do
    case KeyManager.get_node_public_key(cluster_id, sender_id) do
      {:ok, public_key} -> {:ok, public_key}
      {:error, :not_found} -> {:error, :unknown_sender}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_signature(message, public_key) do
    auth_context = extract_auth_context(message)
    
    case sign_message_context(auth_context, nil) do
      {:ok, expected_hash} ->
        case :crypto.verify(:eddsa, :ed25519, expected_hash, message.signature, public_key) do
          true -> :ok
          false -> {:error, :invalid_signature}
        end
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_auth_context(message) do
    payload_hash = hash_payload(message.payload)
    
    %{
      sender_id: message.sender_id,
      cluster_id: message.cluster_id,
      message_type: message.message_type,
      sequence: message.sequence,
      timestamp: message.timestamp,
      nonce: message.nonce,
      payload_hash: payload_hash
    }
  end

  defp check_replay_protection(message) do
    message_id = create_message_id(message)
    
    case :ets.lookup(get_message_cache_table(), message_id) do
      [] ->
        # New message - store it
        timestamp_unix = DateTime.to_unix(message.timestamp)
        :ets.insert(get_message_cache_table(), {message_id, timestamp_unix})
        :ok
        
      [{_id, _stored_timestamp}] ->
        # Already seen this message
        increment_replay_counter()
        {:error, :replay_attack}
    end
  end

  defp validate_sequence_number(message) do
    %{sender_id: sender_id, cluster_id: cluster_id, sequence: sequence} = message
    
    case get_last_sequence(sender_id, cluster_id) do
      {:ok, last_sequence} ->
        cond do
          sequence <= last_sequence ->
            {:error, :invalid_sequence}
          sequence - last_sequence > @sequence_gap_threshold ->
            Logger.warning("Large sequence gap detected", %{
              sender_id: sender_id,
              cluster_id: cluster_id,
              last_sequence: last_sequence,
              current_sequence: sequence
            })
            :ok
          true ->
            :ok
        end
        
      {:error, :not_found} ->
        # First message from this sender
        :ok
    end
  end

  defp sign_message_context(auth_context, private_key) do
    try do
      # Create deterministic message for signing
      signable_data = create_signable_data(auth_context)
      message_hash = :crypto.hash(:sha256, signable_data)
      
      case private_key do
        nil ->
          # Return hash for verification
          {:ok, message_hash}
        key when is_binary(key) ->
          # Sign with private key
          signature = :crypto.sign(:eddsa, :ed25519, message_hash, key)
          {:ok, signature}
      end
    rescue
      error ->
        Logger.error("Failed to sign message context: #{inspect(error)}")
        {:error, :signing_failed}
    end
  end

  defp create_signable_data(auth_context) do
    # Create deterministic binary representation for signing
    fields = [
      auth_context.sender_id,
      auth_context.cluster_id,
      Atom.to_string(auth_context.message_type),
      auth_context.sequence,
      DateTime.to_iso8601(auth_context.timestamp),
      auth_context.nonce,
      auth_context.payload_hash
    ]
    
    :erlang.term_to_binary(fields, [:deterministic])
  end

  defp hash_payload(payload) when is_binary(payload) do
    :crypto.hash(:sha256, payload)
  end
  
  defp hash_payload(payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
  end

  defp generate_nonce() do
    :crypto.strong_rand_bytes(@nonce_size)
  end

  defp create_message_id(message) do
    "#{message.sender_id}:#{message.cluster_id}:#{message.sequence}:#{Base.encode64(message.nonce)}"
  end

  defp get_next_sequence(sender_id, cluster_id) do
    case get_last_sequence(sender_id, cluster_id) do
      {:ok, last_sequence} -> last_sequence + 1
      {:error, :not_found} -> 1
    end
  end

  defp store_sequence(sender_id, cluster_id, sequence) do
    key = "#{sender_id}:#{cluster_id}"
    :ets.insert(get_sequence_table(), {key, sequence, DateTime.utc_now()})
  end

  defp get_last_sequence(sender_id, cluster_id) do
    key = "#{sender_id}:#{cluster_id}"
    
    case :ets.lookup(get_sequence_table(), key) do
      [{_key, sequence, _timestamp}] -> {:ok, sequence}
      [] -> {:error, :not_found}
    end
  end

  defp record_verified_message(message) do
    # Update authentication statistics
    increment_authenticated_counter()
    
    # Optionally store successful verification details for audit
    AuditLogger.log(:debug, "DVT message verification successful", %{
      sender_id: message.sender_id,
      cluster_id: message.cluster_id,
      message_type: message.message_type,
      sequence: message.sequence
    })
  end

  defp cleanup_message_cache(cutoff) do
    cutoff_unix = DateTime.to_unix(cutoff)
    
    # Remove expired entries
    :ets.select_delete(get_message_cache_table(), [
      {{:"$1", :"$2"}, 
       [{:<, :"$2", cutoff_unix}], 
       [true]}
    ])
  end

  defp cleanup_sequence_tracking(cutoff) do
    # Remove sequence entries older than cutoff
    :ets.select_delete(get_sequence_table(), [
      {{:"$1", :"$2", :"$3"}, 
       [{:"<", :"$3", cutoff}], 
       [true]}
    ])
  end

  # ETS table management
  defp get_message_cache_table() do
    case :ets.whereis(:dvt_message_cache) do
      :undefined ->
        :ets.new(:dvt_message_cache, [:set, :public, :named_table])
      table -> table
    end
  end

  defp get_sequence_table() do
    case :ets.whereis(:dvt_sequence_tracking) do
      :undefined ->
        :ets.new(:dvt_sequence_tracking, [:set, :public, :named_table])
      table -> table
    end
  end

  defp get_stats_table() do
    case :ets.whereis(:dvt_auth_stats) do
      :undefined ->
        table = :ets.new(:dvt_auth_stats, [:set, :public, :named_table])
        # Initialize counters
        :ets.insert(table, {:total_authenticated, 0})
        :ets.insert(table, {:authentication_failures, 0})
        :ets.insert(table, {:replay_attempts, 0})
        :ets.insert(table, {:last_cleanup, DateTime.utc_now()})
        table
      table -> table
    end
  end

  defp increment_authenticated_counter() do
    :ets.update_counter(get_stats_table(), :total_authenticated, 1)
  end

  defp increment_failure_counter() do
    :ets.update_counter(get_stats_table(), :authentication_failures, 1)
  end

  defp increment_replay_counter() do
    :ets.update_counter(get_stats_table(), :replay_attempts, 1)
  end

  defp get_total_authenticated() do
    case :ets.lookup(get_stats_table(), :total_authenticated) do
      [{:total_authenticated, count}] -> count
      [] -> 0
    end
  end

  defp get_authentication_failures() do
    case :ets.lookup(get_stats_table(), :authentication_failures) do
      [{:authentication_failures, count}] -> count
      [] -> 0
    end
  end

  defp get_replay_attempts() do
    case :ets.lookup(get_stats_table(), :replay_attempts) do
      [{:replay_attempts, count}] -> count
      [] -> 0
    end
  end

  defp get_active_sequences() do
    :ets.info(get_sequence_table(), :size) || 0
  end

  defp get_cache_size() do
    :ets.info(get_message_cache_table(), :size) || 0
  end

  defp get_last_cleanup() do
    case :ets.lookup(get_stats_table(), :last_cleanup) do
      [{:last_cleanup, timestamp}] -> timestamp
      [] -> nil
    end
  end
end