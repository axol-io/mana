defmodule ExWire.DVT.Crypto do
  @moduledoc """
  DVT (Distributed Validator Technology) cryptographic operations.
  
  This module provides threshold BLS signatures and distributed key generation
  with HSM integration for enterprise-grade validator security.
  """

  alias ExWire.Enterprise.HSMIntegration
  
  # Load the NIF
  @on_load :load_nif
  
  def load_nif do
    nif_file = :filename.join(:code.priv_dir(:ex_wire), 'native/libdvt_crypto')
    :erlang.load_nif(nif_file, 0)
  end
  
  # Default NIF implementations (will be replaced by actual NIFs)
  def generate_threshold_keys(_threshold, _total_nodes), do: :erlang.nif_error(:nif_not_loaded)
  def create_signature_share(_key_share, _message), do: :erlang.nif_error(:nif_not_loaded)
  def aggregate_signature_shares(_public_key_set, _shares, _threshold), do: :erlang.nif_error(:nif_not_loaded)
  def verify_threshold_signature(_public_key, _signature, _message), do: :erlang.nif_error(:nif_not_loaded)
  def verify_signature_share(_public_key_set, _share_data, _message), do: :erlang.nif_error(:nif_not_loaded)
  def reconstruct_secret_key(_key_shares, _threshold), do: :erlang.nif_error(:nif_not_loaded)
  def get_public_key_from_share(_key_share), do: :erlang.nif_error(:nif_not_loaded)
  def validate_threshold_config(_threshold, _total_nodes), do: :erlang.nif_error(:nif_not_loaded)
  
  # DKG NIFs
  def initialize_dkg_round(_node_id, _participants, _threshold, _round_id), do: :erlang.nif_error(:nif_not_loaded)
  def process_dkg_share(_participant, _share_data), do: :erlang.nif_error(:nif_not_loaded)
  def finalize_dkg_round(_participant, _expected_participants, _threshold), do: :erlang.nif_error(:nif_not_loaded)
  def verify_dkg_result(_result, _threshold, _participants), do: :erlang.nif_error(:nif_not_loaded)
  def generate_dkg_complaint(_complainer, _accused, _share, _round_id), do: :erlang.nif_error(:nif_not_loaded)
  def verify_dkg_complaint(_complaint), do: :erlang.nif_error(:nif_not_loaded)

  @type threshold_config :: %{threshold: pos_integer(), total_nodes: pos_integer()}
  @type key_share :: binary()
  @type public_key_set :: binary()
  @type signature_share :: binary()
  @type threshold_signature :: binary()
  @type dkg_participant :: binary()
  @type dkg_result :: binary()

  @doc """
  Generate threshold keys for a DVT cluster with HSM integration.
  
  ## Parameters
  - threshold: Minimum number of signatures required (t)
  - total_nodes: Total number of operators in the cluster (n)
  - hsm_config: Optional HSM configuration for secure key storage
  
  ## Returns
  {:ok, {public_key_set, key_shares}} | {:error, reason}
  """
  @spec generate_dvt_keys(pos_integer(), pos_integer(), map() | nil) :: 
    {:ok, {public_key_set(), list(key_share())}} | {:error, atom()}
  def generate_dvt_keys(threshold, total_nodes, hsm_config \\ nil) do
    with {:ok, true} <- validate_threshold_config(threshold, total_nodes),
         {:ok, {public_key_set, key_shares}} <- generate_threshold_keys(threshold, total_nodes) do
      
      # If HSM is configured, store key shares securely
      case hsm_config do
        nil ->
          {:ok, {public_key_set, key_shares}}
          
        config ->
          case store_key_shares_in_hsm(key_shares, config) do
            {:ok, hsm_key_ids} ->
              # Return HSM key references instead of raw keys
              secure_shares = Enum.map(hsm_key_ids, &create_hsm_key_reference/1)
              {:ok, {public_key_set, secure_shares}}
              
            {:error, reason} ->
              {:error, {:hsm_storage_failed, reason}}
          end
      end
    else
      error -> error
    end
  end

  @doc """
  Create a signature share using a key share (with HSM support).
  
  ## Parameters
  - key_share: Key share data (may be HSM reference)
  - message: Message to sign
  - hsm_config: Optional HSM configuration
  
  ## Returns
  {:ok, signature_share} | {:error, reason}
  """
  @spec create_dvt_signature_share(key_share(), binary(), map() | nil) ::
    {:ok, signature_share()} | {:error, atom()}
  def create_dvt_signature_share(key_share, message, hsm_config \\ nil) do
    case is_hsm_key_reference?(key_share) do
      true ->
        # Use HSM for signing
        with {:ok, hsm_key_id} <- extract_hsm_key_id(key_share),
             {:ok, signature_share} <- sign_with_hsm(hsm_key_id, message, hsm_config) do
          {:ok, signature_share}
        end
        
      false ->
        # Use local key share
        create_signature_share(key_share, message)
    end
  end

  @doc """
  Aggregate signature shares into a threshold signature.
  
  ## Parameters
  - public_key_set: Public key set for verification
  - signature_shares: List of signature shares
  - threshold: Minimum number of shares required
  
  ## Returns
  {:ok, threshold_signature} | {:error, reason}
  """
  @spec aggregate_dvt_signatures(public_key_set(), list(signature_share()), pos_integer()) ::
    {:ok, threshold_signature()} | {:error, atom()}
  def aggregate_dvt_signatures(public_key_set, signature_shares, threshold) do
    if length(signature_shares) >= threshold do
      aggregate_signature_shares(public_key_set, signature_shares, threshold)
    else
      {:error, :insufficient_shares}
    end
  end

  @doc """
  Verify a threshold signature.
  
  ## Parameters
  - public_key: Public key for verification
  - signature: Threshold signature to verify
  - message: Original message that was signed
  
  ## Returns
  {:ok, boolean()} | {:error, reason}
  """
  @spec verify_dvt_signature(binary(), threshold_signature(), binary()) ::
    {:ok, boolean()} | {:error, atom()}
  def verify_dvt_signature(public_key, signature, message) do
    verify_threshold_signature(public_key, signature, message)
  end

  @doc """
  Initialize a DKG round for secure key generation.
  
  ## Parameters
  - node_id: Unique identifier for this node
  - participants: List of all participant node IDs
  - threshold: Threshold for the key generation
  - round_id: Unique identifier for this DKG round
  
  ## Returns
  {:ok, {dkg_participant, initial_shares}} | {:error, reason}
  """
  @spec initialize_dkg(pos_integer(), list(pos_integer()), pos_integer(), String.t()) ::
    {:ok, {dkg_participant(), list(binary())}} | {:error, atom()}
  def initialize_dkg(node_id, participants, threshold, round_id \\ nil) do
    round_id = round_id || generate_round_id()
    
    with {:ok, true} <- validate_threshold_config(threshold, length(participants)),
         true <- node_id in participants do
      initialize_dkg_round(node_id, participants, threshold, round_id)
    else
      false -> {:error, :node_not_in_participants}
      error -> error
    end
  end

  @doc """
  Process a received DKG share during key generation.
  
  ## Parameters
  - participant: Current DKG participant state
  - share_data: Share data received from another participant
  
  ## Returns
  {:ok, updated_participant} | {:error, reason}
  """
  @spec process_dkg_share_data(dkg_participant(), binary()) ::
    {:ok, dkg_participant()} | {:error, atom()}
  def process_dkg_share_data(participant, share_data) do
    process_dkg_share(participant, share_data)
  end

  @doc """
  Finalize DKG round and compute the final key share.
  
  ## Parameters
  - participant: Final DKG participant state
  - expected_participants: List of expected participant IDs
  - threshold: Threshold configuration
  - hsm_config: Optional HSM configuration for secure storage
  
  ## Returns
  {:ok, dkg_result} | {:error, reason}
  """
  @spec finalize_dkg(dkg_participant(), list(pos_integer()), pos_integer(), map() | nil) ::
    {:ok, dkg_result()} | {:error, atom()}
  def finalize_dkg(participant, expected_participants, threshold, hsm_config \\ nil) do
    with {:ok, dkg_result} <- finalize_dkg_round(participant, expected_participants, threshold),
         {:ok, true} <- verify_dkg_result(dkg_result, threshold, expected_participants) do
      
      case hsm_config do
        nil ->
          {:ok, dkg_result}
          
        config ->
          # Store the generated key share in HSM
          case store_dkg_result_in_hsm(dkg_result, config) do
            {:ok, hsm_result} -> {:ok, hsm_result}
            error -> error
          end
      end
    end
  end

  @doc """
  Generate a complaint against a malicious DKG participant.
  
  ## Parameters
  - complainer_id: ID of the complaining node
  - accused_id: ID of the accused node
  - invalid_share: The invalid share received
  - round_id: DKG round identifier
  
  ## Returns
  {:ok, complaint_data} | {:error, reason}
  """
  @spec generate_complaint(pos_integer(), pos_integer(), binary(), String.t()) ::
    {:ok, binary()} | {:error, atom()}
  def generate_complaint(complainer_id, accused_id, invalid_share, round_id) do
    generate_dkg_complaint(complainer_id, accused_id, invalid_share, round_id)
  end

  @doc """
  Verify a DKG complaint.
  
  ## Parameters
  - complaint: Complaint data to verify
  
  ## Returns
  {:ok, boolean()} | {:error, reason}
  """
  @spec verify_complaint(binary()) :: {:ok, boolean()} | {:error, atom()}
  def verify_complaint(complaint) do
    verify_dkg_complaint(complaint)
  end

  # Private helper functions

  defp store_key_shares_in_hsm(key_shares, hsm_config) do
    case HSMIntegration.get_provider(hsm_config) do
      {:ok, provider} ->
        key_shares
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {share, index}, {:ok, acc} ->
          key_id = "dvt_key_share_#{index}_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
          
          case HSMIntegration.store_key(provider, key_id, share, %{type: :dvt_share}) do
            {:ok, _} -> {:cont, {:ok, [key_id | acc]}}
            error -> {:halt, error}
          end
        end)
        
      error -> error
    end
  end

  defp create_hsm_key_reference(key_id) do
    %{type: :hsm_reference, key_id: key_id, created_at: DateTime.utc_now()}
    |> :erlang.term_to_binary()
  end

  defp is_hsm_key_reference?(key_data) do
    try do
      case :erlang.binary_to_term(key_data) do
        %{type: :hsm_reference} -> true
        _ -> false
      end
    rescue
      _ -> false
    end
  end

  defp extract_hsm_key_id(key_reference) do
    try do
      case :erlang.binary_to_term(key_reference) do
        %{type: :hsm_reference, key_id: key_id} -> {:ok, key_id}
        _ -> {:error, :invalid_hsm_reference}
      end
    rescue
      _ -> {:error, :invalid_hsm_reference}
    end
  end

  defp sign_with_hsm(key_id, message, hsm_config) do
    case HSMIntegration.get_provider(hsm_config) do
      {:ok, provider} ->
        HSMIntegration.sign(provider, key_id, message, %{algorithm: :bls12_381})
        
      error -> error
    end
  end

  defp store_dkg_result_in_hsm(dkg_result, hsm_config) do
    # Extract key share from DKG result and store in HSM
    case decode_dkg_result(dkg_result) do
      {:ok, %{secret_key_share: key_share} = result} ->
        case HSMIntegration.get_provider(hsm_config) do
          {:ok, provider} ->
            key_id = "dvt_dkg_result_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
            
            case HSMIntegration.store_key(provider, key_id, key_share, %{type: :dvt_dkg_result}) do
              {:ok, _} ->
                # Return DKG result with HSM reference instead of raw key
                hsm_result = %{result | secret_key_share: create_hsm_key_reference(key_id)}
                {:ok, :erlang.term_to_binary(hsm_result)}
                
              error -> error
            end
            
          error -> error
        end
        
      error -> error
    end
  end

  defp decode_dkg_result(dkg_result) do
    try do
      decoded = :erlang.binary_to_term(dkg_result)
      {:ok, decoded}
    rescue
      _ -> {:error, :invalid_dkg_result}
    end
  end

  defp generate_round_id do
    "dkg_round_#{DateTime.utc_now() |> DateTime.to_unix()}_#{:crypto.strong_rand_bytes(4) |> Base.encode16()}"
  end
end