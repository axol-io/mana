defmodule ExWire.Layer2.ZK.ZKRollup do
  @moduledoc """
  Zero-knowledge rollup implementation supporting multiple proof systems.

  Supports:
  - zkSync Era (PLONK-based)
  - StarkNet (STARK-based)
  - Polygon zkEVM (fflonk)
  - Scroll (Halo2)

  Features:
  - Multiple proof system verification
  - Proof aggregation
  - Circuit-specific handlers
  - Efficient state updates
  """

  use GenServer
  require Logger

  alias ExWire.Layer2.Rollup
  alias ExWire.Layer2.ZK.{ProofVerifier, StateTree}

  @type proof_system :: :groth16 | :plonk | :stark | :fflonk | :halo2
  @type proof_status :: :pending | :verified | :rejected

  @type t :: %__MODULE__{
          rollup_id: String.t(),
          proof_system: proof_system(),
          verifier_contract: binary(),
          state_tree: StateTree.t(),
          pending_proofs: map(),
          verified_batches: list(),
          circuit_config: map()
        }

  defstruct [
    :rollup_id,
    :proof_system,
    :verifier_contract,
    :state_tree,
    :circuit_config,
    pending_proofs: %{},
    verified_batches: []
  ]

  # Client API

  @doc """
  Starts a ZK rollup manager.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:rollup_id]))
  end

  @doc """
  Submits a validity proof for a batch.
  """
  @spec submit_proof(String.t(), non_neg_integer(), binary(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  def submit_proof(rollup_id, batch_number, proof, public_inputs) do
    GenServer.call(via_tuple(rollup_id), {:submit_proof, batch_number, proof, public_inputs})
  end

  @doc """
  Verifies a proof and updates state if valid.
  """
  @spec verify_and_update(String.t(), String.t()) ::
          {:ok, :verified} | {:error, term()}
  def verify_and_update(rollup_id, proof_id) do
    GenServer.call(via_tuple(rollup_id), {:verify_and_update, proof_id})
  end

  @doc """
  Aggregates multiple proofs into a single proof.
  """
  @spec aggregate_proofs(String.t(), list(String.t())) ::
          {:ok, binary()} | {:error, term()}
  def aggregate_proofs(rollup_id, proof_ids) do
    GenServer.call(via_tuple(rollup_id), {:aggregate_proofs, proof_ids})
  end

  @doc """
  Gets the current state tree root.
  """
  @spec get_state_tree_root(String.t()) :: {:ok, binary()} | {:error, term()}
  def get_state_tree_root(rollup_id) do
    GenServer.call(via_tuple(rollup_id), :get_state_tree_root)
  end

  @doc """
  Updates account state in the state tree.
  """
  @spec update_account_state(String.t(), binary(), map()) :: :ok | {:error, term()}
  def update_account_state(rollup_id, account_address, new_state) do
    GenServer.call(via_tuple(rollup_id), {:update_account_state, account_address, new_state})
  end

  @doc """
  Gets proof verification status.
  """
  @spec get_proof_status(String.t(), String.t()) ::
          {:ok, proof_status()} | {:error, :not_found}
  def get_proof_status(rollup_id, proof_id) do
    GenServer.call(via_tuple(rollup_id), {:get_proof_status, proof_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info(
      "Starting ZK Rollup: #{opts[:rollup_id]} with proof system: #{opts[:proof_system]}"
    )

    # Initialize state tree
    {:ok, state_tree} = StateTree.new(opts[:state_tree_depth] || 32)

    state = %__MODULE__{
      rollup_id: opts[:rollup_id],
      proof_system: opts[:proof_system] || :plonk,
      verifier_contract: opts[:verifier_contract],
      state_tree: state_tree,
      circuit_config: load_circuit_config(opts[:proof_system])
    }

    # Start the base rollup process
    {:ok, _pid} =
      Rollup.start_link(
        id: opts[:rollup_id],
        type: :zk,
        config: %{
          proof_system: state.proof_system,
          verification_gas_limit: 500_000,
          max_batch_size: 500
        }
      )

    # Initialize proof verifier
    ProofVerifier.init(state.proof_system, state.circuit_config)

    {:ok, _state}
  end

  @impl true
  def handle_call({:submit_proof, batch_number, proof, public_inputs}, _from, _state) do
    proof_id = generate_proof_id()

    proof_data = %{
      id: proof_id,
      batch_number: batch_number,
      proof: proof,
      public_inputs: public_inputs,
      submitted_at: DateTime.utc_now(),
      status: :pending,
      proof_system: state.proof_system
    }

    new_pending_proofs = Map.put(state.pending_proofs, proof_id, proof_data)

    Logger.info("Proof submitted: #{proof_id} for batch #{batch_number}")

    # Start async verification
    Task.start(fn ->
      verify_proof_async(state.rollup_id, proof_id)
    end)

    {:reply, {:ok, proof_id}, %{state | pending_proofs: new_pending_proofs}}
  end

  @impl true
  def handle_call({:verify_and_update, proof_id}, _from, _state) do
    case Map.get(state.pending_proofs, proof_id) do
      nil ->
        {:reply, {:error, :proof_not_found}, state}

      proof_data when proof_data.status != :pending ->
        {:reply, {:error, :proof_already_processed}, state}

      proof_data ->
        case verify_proof(proof_data, state) do
          {:ok, true} ->
            # Update state tree with verified state transition
            case update_state_tree(state.state_tree, proof_data.public_inputs) do
              {:ok, new_state_tree} ->
                updated_proof = %{proof_data | status: :verified}
                new_pending_proofs = Map.put(state.pending_proofs, proof_id, updated_proof)
                new_verified_batches = [proof_data.batch_number | state.verified_batches]

                Logger.info("Proof verified and state updated: #{proof_id}")

                {:reply, {:ok, :verified},
                 %{
                   state
                   | pending_proofs: new_pending_proofs,
                     verified_batches: new_verified_batches,
                     state_tree: new_state_tree
                 }}

              {:error, _reason} = error ->
                {:reply, error, state}
            end

          {:ok, false} ->
            updated_proof = %{proof_data | status: :rejected}
            new_pending_proofs = Map.put(state.pending_proofs, proof_id, updated_proof)

            Logger.warning("Proof rejected: #{proof_id}")

            {:reply, {:error, :invalid_proof}, %{state | pending_proofs: new_pending_proofs}}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:aggregate_proofs, proof_ids}, _from, _state) do
    proofs =
      Enum.map(proof_ids, fn id ->
        Map.get(state.pending_proofs, id)
      end)

    if Enum.any?(proofs, &is_nil/1) do
      {:reply, {:error, :proof_not_found}, state}
    else
      case aggregate_proofs_internal(proofs, state.proof_system) do
        {:ok, aggregated_proof} ->
          Logger.info("Aggregated #{length(proof_ids)} proofs")
          {:reply, {:ok, aggregated_proof}, state}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call(:get_state_tree_root, _from, _state) do
    root = StateTree.get_root(state.state_tree)
    {:reply, {:ok, root}, state}
  end

  @impl true
  def handle_call({:update_account_state, account_address, new_state}, _from, _state) do
    case StateTree.update_account(state.state_tree, account_address, new_state) do
      {:ok, new_state_tree} ->
        Logger.debug("Updated account state for #{Base.encode16(account_address)}")
        {:reply, :ok, %{state | state_tree: new_state_tree}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_proof_status, proof_id}, _from, _state) do
    case Map.get(state.pending_proofs, proof_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      proof_data ->
        {:reply, {:ok, proof_data.status}, state}
    end
  end

  @impl true
  def handle_info({:proof_verified, proof_id, result}, _state) do
    # Handle async proof verification result
    case Map.get(state.pending_proofs, proof_id) do
      nil ->
        {:noreply, _state}

      proof_data ->
        updated_proof = %{proof_data | status: if(result, do: :verified, else: :rejected)}
        new_pending_proofs = Map.put(state.pending_proofs, proof_id, updated_proof)

        if result do
          Logger.info("Async proof verification successful: #{proof_id}")
        else
          Logger.warning("Async proof verification failed: #{proof_id}")
        end

        {:noreply, %{state | pending_proofs: new_pending_proofs}}
    end
  end

  # Private Functions

  defp via_tuple(rollup_id) do
    {:via, Registry, {ExWire.Layer2.ZKRegistry, rollup_id}}
  end

  defp generate_proof_id() do
    "proof_" <> Base.encode16(:crypto.strong_rand_bytes(16))
  end

  defp load_circuit_config(:groth16) do
    %{
      proving_key_path: "circuits/groth16/proving_key.bin",
      verification_key_path: "circuits/groth16/verification_key.json",
      constraint_system: "r1cs",
      curve: "bn254"
    }
  end

  defp load_circuit_config(:plonk) do
    %{
      srs_path: "circuits/plonk/srs.bin",
      verification_key: "circuits/plonk/vk.json",
      gates: ["add", "mul", "custom"],
      permutation_argument: true
    }
  end

  defp load_circuit_config(:stark) do
    %{
      field: "stark252",
      fri_parameters: %{
        expansion_factor: 8,
        num_queries: 30
      },
      hash_function: "poseidon"
    }
  end

  defp load_circuit_config(:fflonk) do
    %{
      srs_path: "circuits/fflonk/srs.bin",
      verification_key: "circuits/fflonk/vk.json",
      polynomial_commitment: "kate",
      lookup_tables: true
    }
  end

  defp load_circuit_config(:halo2) do
    %{
      # 2^13 rows
      k: 13,
      verification_key: "circuits/halo2/vk.json",
      lookup_enabled: true,
      custom_gates: ["ecc", "range_check"]
    }
  end

  defp load_circuit_config(_), do: %{}

  defp verify_proof(proof_data, _state) do
    case state.proof_system do
      :groth16 ->
        ProofVerifier.verify_groth16(
          proof_data.proof,
          proof_data.public_inputs,
          state.circuit_config
        )

      :plonk ->
        ProofVerifier.verify_plonk(
          proof_data.proof,
          proof_data.public_inputs,
          state.circuit_config
        )

      :stark ->
        ProofVerifier.verify_stark(
          proof_data.proof,
          proof_data.public_inputs,
          state.circuit_config
        )

      :fflonk ->
        ProofVerifier.verify_fflonk(
          proof_data.proof,
          proof_data.public_inputs,
          state.circuit_config
        )

      :halo2 ->
        ProofVerifier.verify_halo2(
          proof_data.proof,
          proof_data.public_inputs,
          _state.circuit_config
        )

      _ ->
        {:error, :unsupported_proof_system}
    end
  end

  defp update_state_tree(state_tree, public_inputs) do
    # Extract state transition from public inputs
    # Format depends on the specific rollup implementation

    # For now, simulate state tree update
    {:ok, state_tree}
  end

  defp aggregate_proofs_internal(proofs, proof_system) do
    # Aggregate multiple proofs into one
    # This is proof-system specific

    case proof_system do
      :groth16 ->
        # Groth16 doesn't support native aggregation
        # Would need a recursive SNARK
        {:error, :aggregation_not_supported}

      :plonk ->
        # PLONK supports proof aggregation
        ProofVerifier.aggregate_plonk_proofs(proofs)

      :stark ->
        # STARK proofs can be recursively composed
        ProofVerifier.aggregate_stark_proofs(proofs)

      :halo2 ->
        # Halo2 supports accumulation
        ProofVerifier.aggregate_halo2_proofs(proofs)

      _ ->
        {:error, :aggregation_not_supported}
    end
  end

  defp verify_proof_async(rollup_id, proof_id) do
    # Simulate async proof verification
    Process.sleep(1000)

    # In production, this would call the actual verifier
    # 80% success rate for testing
    result = :rand.uniform(10) > 2

    send(via_tuple(rollup_id) |> GenServer.whereis(), {:proof_verified, proof_id, result})
  end
end
