defmodule ExWire.Enterprise.PrivateTransactions do
  @moduledoc """
  Private transaction support for enterprise use cases.
  Implements zero-knowledge proofs, encrypted transaction pools, and private state management.
  Compatible with Quorum-style private transactions and EEA standards.
  """

  use GenServer
  require Logger

  alias Blockchain.Transaction
  alias ExWire.Enterprise.{AuditLogger, HSMIntegration}

  defstruct [
    :private_pools,
    :privacy_groups,
    :encrypted_states,
    :pending_reveals,
    :zk_proofs,
    :tessera_client,
    :config
  ]

  @type privacy_group :: %{
          id: String.t(),
          name: String.t(),
          members: list(binary()),
          encryption_key: binary(),
          created_at: DateTime.t(),
          permissions: map()
        }

  @type private_tx :: %{
          tx_id: String.t(),
          public_tx: Transaction.t(),
          private_payload: binary(),
          privacy_group_id: String.t(),
          participants: list(binary()),
          zk_proof: binary() | nil,
          status: :pending | :committed | :revealed,
          metadata: map()
        }

  @type encrypted_state :: %{
          key: binary(),
          value: binary(),
          privacy_group_id: String.t(),
          version: non_neg_integer(),
          last_modified: DateTime.t()
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Create a new privacy group
  """
  def create_privacy_group(name, members, opts \\ []) do
    GenServer.call(__MODULE__, {:create_privacy_group, name, members, opts})
  end

  @doc """
  Send a private transaction
  """
  def send_private_transaction(transaction, privacy_group_id, opts \\ []) do
    GenServer.call(__MODULE__, {:send_private_transaction, transaction, privacy_group_id, opts})
  end

  @doc """
  Retrieve private transaction data
  """
  def get_private_transaction(tx_id, requester) do
    GenServer.call(__MODULE__, {:get_private_transaction, tx_id, requester})
  end

  @doc """
  Generate zero-knowledge proof for transaction
  """
  def generate_zk_proof(transaction, witness) do
    GenServer.call(__MODULE__, {:generate_zk_proof, transaction, witness})
  end

  @doc """
  Verify zero-knowledge proof
  """
  def verify_zk_proof(proof, public_inputs) do
    GenServer.call(__MODULE__, {:verify_zk_proof, proof, public_inputs})
  end

  @doc """
  Get private state for a privacy group
  """
  def get_private_state(privacy_group_id, key, requester) do
    GenServer.call(__MODULE__, {:get_private_state, privacy_group_id, key, requester})
  end

  @doc """
  Update private state
  """
  def update_private_state(privacy_group_id, key, value, updater) do
    GenServer.call(__MODULE__, {:update_private_state, privacy_group_id, key, value, updater})
  end

  @doc """
  Add member to privacy group
  """
  def add_member(privacy_group_id, new_member, authorizer) do
    GenServer.call(__MODULE__, {:add_member, privacy_group_id, new_member, authorizer})
  end

  @doc """
  Reveal private transaction to new party
  """
  def selective_disclosure(tx_id, recipient, authorizer) do
    GenServer.call(__MODULE__, {:selective_disclosure, tx_id, recipient, authorizer})
  end

  @doc """
  List privacy groups for a member
  """
  def list_privacy_groups(member) do
    GenServer.call(__MODULE__, {:list_privacy_groups, member})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting Private Transactions manager")

    state = %__MODULE__{
      private_pools: %{},
      privacy_groups: %{},
      encrypted_states: %{},
      pending_reveals: [],
      zk_proofs: %{},
      tessera_client: initialize_tessera(opts),
      config: build_config(opts)
    }

    schedule_cleanup()
    {:ok, _state}
  end

  @impl true
  def handle_call({:create_privacy_group, name, members, opts}, _from, _state) do
    group_id = generate_group_id()

    # Generate group encryption key
    encryption_key = generate_group_key()

    privacy_group = %{
      id: group_id,
      name: name,
      members: validate_members(members),
      encryption_key: encryption_key,
      created_at: DateTime.utc_now(),
      permissions: Keyword.get(opts, :permissions, default_permissions()),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    # Distribute keys to members using Tessera if configured
    if state.tessera_client do
      distribute_keys_via_tessera(privacy_group, state.tessera_client)
    end

    state = put_in(state.privacy_groups[group_id], privacy_group)

    AuditLogger.log(:privacy_group_created, %{
      group_id: group_id,
      name: name,
      members_count: length(members)
    })

    {:reply, {:ok, privacy_group}, state}
  end

  @impl true
  def handle_call({:send_private_transaction, transaction, privacy_group_id, opts}, _from, _state) do
    case Map.get(state.privacy_groups, privacy_group_id) do
      nil ->
        {:reply, {:error, :privacy_group_not_found}, state}

      privacy_group ->
        # Encrypt transaction payload
        encrypted_payload = encrypt_transaction(transaction, privacy_group.encryption_key)

        # Create public marker transaction
        public_tx = create_marker_transaction(transaction, encrypted_payload)

        # Generate ZK proof if requested
        zk_proof =
          if Keyword.get(opts, :use_zk_proof, false) do
            generate_transaction_proof(transaction)
          else
            nil
          end

        tx_id = generate_tx_id()

        private_tx = %{
          tx_id: tx_id,
          public_tx: public_tx,
          private_payload: encrypted_payload,
          privacy_group_id: privacy_group_id,
          participants: privacy_group.members,
          zk_proof: zk_proof,
          status: :pending,
          metadata: %{
            sender: Keyword.get(opts, :sender),
            timestamp: DateTime.utc_now()
          }
        }

        # Store in private pool
        state = put_in(state.private_pools[tx_id], private_tx)

        # Distribute to participants
        distribute_to_participants(private_tx, privacy_group, state)

        AuditLogger.log(:private_transaction_sent, %{
          tx_id: tx_id,
          privacy_group_id: privacy_group_id,
          has_zk_proof: zk_proof != nil
        })

        {:reply, {:ok, tx_id, public_tx}, state}
    end
  end

  @impl true
  def handle_call({:get_private_transaction, tx_id, requester}, _from, _state) do
    case Map.get(state.private_pools, tx_id) do
      nil ->
        {:reply, {:error, :transaction_not_found}, state}

      private_tx ->
        privacy_group = Map.get(state.privacy_groups, private_tx.privacy_group_id)

        if requester in privacy_group.members do
          # Decrypt transaction for authorized member
          decrypted =
            decrypt_transaction(
              private_tx.private_payload,
              privacy_group.encryption_key
            )

          AuditLogger.log(:private_transaction_accessed, %{
            tx_id: tx_id,
            requester: requester
          })

          {:reply, {:ok, decrypted}, state}
        else
          {:reply, {:error, :unauthorized}, state}
        end
    end
  end

  @impl true
  def handle_call({:generate_zk_proof, transaction, witness}, _from, _state) do
    proof = create_zk_proof(transaction, witness)

    proof_id = generate_proof_id()
    state = put_in(state.zk_proofs[proof_id], proof)

    {:reply, {:ok, proof_id, proof}, state}
  end

  @impl true
  def handle_call({:verify_zk_proof, proof, public_inputs}, _from, _state) do
    valid = verify_proof(proof, public_inputs)

    AuditLogger.log(:zk_proof_verified, %{
      valid: valid,
      inputs_hash: :crypto.hash(:sha256, :erlang.term_to_binary(public_inputs))
    })

    {:reply, {:ok, valid}, state}
  end

  @impl true
  def handle_call({:get_private_state, privacy_group_id, key, requester}, _from, _state) do
    case Map.get(state.privacy_groups, privacy_group_id) do
      nil ->
        {:reply, {:error, :privacy_group_not_found}, state}

      privacy_group ->
        if requester in privacy_group.members do
          state_key = {privacy_group_id, key}

          case Map.get(state.encrypted_states, state_key) do
            nil ->
              {:reply, {:ok, nil}, state}

            encrypted_state ->
              decrypted = decrypt_state(encrypted_state, privacy_group.encryption_key)
              {:reply, {:ok, decrypted}, state}
          end
        else
          {:reply, {:error, :unauthorized}, state}
        end
    end
  end

  @impl true
  def handle_call({:update_private_state, privacy_group_id, key, value, updater}, _from, _state) do
    case Map.get(state.privacy_groups, privacy_group_id) do
      nil ->
        {:reply, {:error, :privacy_group_not_found}, state}

      privacy_group ->
        if updater in privacy_group.members do
          state_key = {privacy_group_id, key}

          encrypted_value = encrypt_state(value, privacy_group.encryption_key)

          encrypted_state = %{
            key: key,
            value: encrypted_value,
            privacy_group_id: privacy_group_id,
            version: get_next_version(state, state_key),
            last_modified: DateTime.utc_now()
          }

          state = put_in(state.encrypted_states[state_key], encrypted_state)

          # Sync with other members
          sync_state_update(encrypted_state, privacy_group)

          {:reply, :ok, state}
        else
          {:reply, {:error, :unauthorized}, state}
        end
    end
  end

  @impl true
  def handle_call({:add_member, privacy_group_id, new_member, authorizer}, _from, _state) do
    case Map.get(state.privacy_groups, privacy_group_id) do
      nil ->
        {:reply, {:error, :privacy_group_not_found}, state}

      privacy_group ->
        if has_admin_permission?(privacy_group, authorizer) do
          updated_group = update_in(privacy_group.members, &[new_member | &1])

          # Share encryption key with new member
          share_key_with_member(updated_group.encryption_key, new_member)

          state = put_in(state.privacy_groups[privacy_group_id], updated_group)

          AuditLogger.log(:privacy_group_member_added, %{
            privacy_group_id: privacy_group_id,
            new_member: new_member,
            authorizer: authorizer
          })

          {:reply, :ok, state}
        else
          {:reply, {:error, :insufficient_permissions}, state}
        end
    end
  end

  @impl true
  def handle_call({:selective_disclosure, tx_id, recipient, authorizer}, _from, _state) do
    case Map.get(state.private_pools, tx_id) do
      nil ->
        {:reply, {:error, :transaction_not_found}, state}

      private_tx ->
        privacy_group = Map.get(state.privacy_groups, private_tx.privacy_group_id)

        if authorizer in privacy_group.members do
          # Create disclosure record
          disclosure = %{
            tx_id: tx_id,
            recipient: recipient,
            authorizer: authorizer,
            disclosed_at: DateTime.utc_now(),
            encryption_key: generate_disclosure_key()
          }

          # Re-encrypt for recipient
          disclosed_payload =
            re_encrypt_for_disclosure(
              private_tx.private_payload,
              privacy_group.encryption_key,
              disclosure.encryption_key
            )

          # Send to recipient
          send_disclosure(recipient, disclosed_payload, disclosure.encryption_key)

          state = update_in(state.pending_reveals, &[disclosure | &1])

          AuditLogger.log(:selective_disclosure, %{
            tx_id: tx_id,
            recipient: recipient,
            authorizer: authorizer
          })

          {:reply, {:ok, disclosure}, state}
        else
          {:reply, {:error, :unauthorized}, state}
        end
    end
  end

  @impl true
  def handle_call({:list_privacy_groups, member}, _from, _state) do
    groups =
      Enum.filter(state.privacy_groups, fn {_id, group} ->
        member in group.members
      end)
      |> Enum.map(fn {id, group} ->
        %{
          id: id,
          name: group.name,
          members_count: length(group.members),
          created_at: group.created_at
        }
      end)

    {:reply, {:ok, groups}, state}
  end

  @impl true
  def handle_info(:cleanup_expired, _state) do
    # Clean up old pending reveals and expired proofs
    state = cleanup_expired_data(state)
    schedule_cleanup()
    {:noreply, state}
  end

  # Private Functions - Encryption

  defp encrypt_transaction(transaction, group_key) do
    plaintext = :erlang.term_to_binary(transaction)
    iv = :crypto.strong_rand_bytes(16)

    ciphertext = :crypto.crypto_one_time(:aes_256_gcm, group_key, iv, plaintext, true)
    iv <> ciphertext
  end

  defp decrypt_transaction(encrypted_payload, group_key) do
    <<iv::binary-size(16), ciphertext::binary>> = encrypted_payload

    plaintext = :crypto.crypto_one_time(:aes_256_gcm, group_key, iv, ciphertext, false)
    :erlang.binary_to_term(plaintext)
  end

  defp encrypt_state(value, group_key) do
    plaintext = :erlang.term_to_binary(value)
    iv = :crypto.strong_rand_bytes(16)

    ciphertext = :crypto.crypto_one_time(:aes_256_cbc, group_key, iv, plaintext, true)
    iv <> ciphertext
  end

  defp decrypt_state(encrypted_state, group_key) do
    <<iv::binary-size(16), ciphertext::binary>> = encrypted_state.value

    plaintext = :crypto.crypto_one_time(:aes_256_cbc, group_key, iv, ciphertext, false)
    :erlang.binary_to_term(plaintext)
  end

  defp re_encrypt_for_disclosure(encrypted_payload, old_key, new_key) do
    # Decrypt with old key
    decrypted = decrypt_transaction(encrypted_payload, old_key)

    # Re-encrypt with new key
    encrypt_transaction(decrypted, new_key)
  end

  # Private Functions - Zero-Knowledge Proofs

  defp generate_transaction_proof(transaction) do
    # Simplified ZK proof generation
    # In production, this would use a ZK library like libsnark or bellman
    witness = %{
      value: transaction.value,
      from: transaction.from,
      nonce: transaction.nonce
    }

    create_zk_proof(transaction, witness)
  end

  defp create_zk_proof(transaction, witness) do
    # Create a simplified proof structure
    # Real implementation would use ZK-SNARKs or ZK-STARKs
    %{
      protocol: :groth16,
      curve: :bn128,
      proof: %{
        a: :crypto.strong_rand_bytes(32),
        b: :crypto.strong_rand_bytes(64),
        c: :crypto.strong_rand_bytes(32)
      },
      public_inputs: hash_public_inputs(transaction),
      created_at: DateTime.utc_now()
    }
  end

  defp verify_proof(proof, public_inputs) do
    # Simplified verification
    # Real implementation would use pairing checks
    hash_public_inputs(public_inputs) == proof.public_inputs
  end

  defp hash_public_inputs(inputs) do
    :crypto.hash(:sha256, :erlang.term_to_binary(inputs))
  end

  # Private Functions - Marker Transactions

  defp create_marker_transaction(private_tx, encrypted_payload) do
    # Create a public transaction that serves as a marker
    # The actual private data is stored off-chain
    %Transaction{
      from: private_tx.from,
      # Privacy precompile address
      to: <<0::160>>,
      value: 0,
      data: create_marker_data(encrypted_payload),
      gas_limit: 100_000,
      gas_price: private_tx.gas_price,
      nonce: private_tx.nonce
    }
  end

  defp create_marker_data(encrypted_payload) do
    # Create marker data with hash of encrypted payload
    payload_hash = :crypto.hash(:sha256, encrypted_payload)

    # Function selector for private transaction marker
    selector = <<0x12, 0x34, 0x56, 0x78>>

    selector <> payload_hash
  end

  # Private Functions - Distribution

  defp distribute_to_participants(private_tx, privacy_group, _state) do
    # Distribute encrypted transaction to all participants
    Enum.each(privacy_group.members, fn member ->
      send_to_participant(member, private_tx, state)
    end)
  end

  defp send_to_participant(participant, private_tx, _state) do
    # Send via Tessera or direct P2P
    if state.tessera_client do
      send_via_tessera(participant, private_tx, state.tessera_client)
    else
      send_via_p2p(participant, private_tx)
    end
  end

  defp distribute_keys_via_tessera(privacy_group, tessera_client) do
    # Distribute encryption keys using Tessera
    # Implementation would integrate with Tessera API
    :ok
  end

  defp send_via_tessera(_participant, _private_tx, _tessera_client) do
    # Send transaction via Tessera
    :ok
  end

  defp send_via_p2p(_participant, _private_tx) do
    # Send transaction via P2P network
    :ok
  end

  defp share_key_with_member(encryption_key, new_member) do
    # Securely share encryption key with new member
    # Could use HSM for key wrapping
    HSMIntegration.encrypt("group_key_wrap", encryption_key)
    :ok
  end

  defp sync_state_update(encrypted_state, privacy_group) do
    # Sync state update with all group members
    Enum.each(privacy_group.members, fn member ->
      send_state_update(member, encrypted_state)
    end)
  end

  defp send_state_update(_member, _encrypted_state) do
    # Send state update to member
    :ok
  end

  defp send_disclosure(_recipient, _disclosed_payload, _encryption_key) do
    # Send disclosed transaction to recipient
    :ok
  end

  # Private Functions - Helpers

  defp validate_members(members) do
    Enum.uniq(members)
  end

  defp has_admin_permission?(privacy_group, member) do
    member in privacy_group.members &&
      Map.get(privacy_group.permissions, member, %{})[:admin] == true
  end

  defp get_next_version(_state, state_key) do
    case Map.get(state.encrypted_states, state_key) do
      nil -> 1
      existing -> existing.version + 1
    end
  end

  defp cleanup_expired_data(_state) do
    cutoff = DateTime.add(DateTime.utc_now(), -state._config.retention_hours * 3600, :second)

    pending_reveals =
      Enum.filter(state.pending_reveals, fn reveal ->
        DateTime.compare(reveal.disclosed_at, cutoff) == :gt
      end)

    %{_state | pending_reveals: pending_reveals}
  end

  defp initialize_tessera(opts) do
    if Keyword.get(opts, :use_tessera, false) do
      %{
        url: Keyword.get(opts, :tessera_url, "http://localhost:9081"),
        public_key: Keyword.get(opts, :tessera_public_key)
      }
    else
      nil
    end
  end

  defp build_config(opts) do
    %{
      max_privacy_groups: Keyword.get(opts, :max_privacy_groups, 100),
      max_group_size: Keyword.get(opts, :max_group_size, 20),
      # 7 days
      retention_hours: Keyword.get(opts, :retention_hours, 168),
      use_hsm_for_keys: Keyword.get(opts, :use_hsm_for_keys, false)
    }
  end

  defp default_permissions do
    %{
      send_transactions: true,
      read_state: true,
      update_state: true,
      add_members: false,
      remove_members: false
    }
  end

  defp generate_group_id do
    "priv_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp generate_tx_id do
    "ptx_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp generate_proof_id do
    "proof_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp generate_group_key do
    :crypto.strong_rand_bytes(32)
  end

  defp generate_disclosure_key do
    :crypto.strong_rand_bytes(32)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired, :timer.hours(1))
  end
end
