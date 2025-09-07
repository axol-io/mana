defmodule ExWire.Layer2.Optimism.FaultDisputeGame do
  @moduledoc """
  Implementation of Optimism's Fault Dispute Game for the Cannon fault proof system.

  The dispute game uses a bisection protocol to narrow down the exact instruction
  where the disagreement occurs, then runs a single instruction on-chain to 
  determine the winner.

  Key concepts:
  - Game tree with claims and counter-claims
  - Bisection to find disagreement point
  - MIPS VM for on-chain execution
  - Clock-based timing for moves
  """

  use GenServer
  require Logger

  # Game constants from Optimism specs
  # Sufficient for 2^36 instructions
  @max_game_depth 73
  # 7 days in seconds
  @game_duration 7 * 24 * 60 * 60
  # Depth where we switch from execution to block bisection
  @split_depth 30
  # 3.5 days per player
  @max_clock_duration 3.5 * 24 * 60 * 60

  @type game_status :: :in_progress | :challenger_wins | :defender_wins | :draw
  @type position :: non_neg_integer()

  @type claim :: %{
          parent_index: non_neg_integer() | nil,
          countered_by: binary() | nil,
          claimant: binary(),
          bond: non_neg_integer(),
          claim: binary(),
          position: position(),
          clock: non_neg_integer()
        }

  @type t :: %__MODULE__{
          game_id: String.t(),
          root_claim: binary(),
          status: game_status(),
          claims: list(claim()),
          created_at: DateTime.t(),
          resolved_at: DateTime.t() | nil,
          l2_block_number: non_neg_integer(),
          starting_output_root: binary(),
          disputed_output_root: binary(),
          current_depth: non_neg_integer()
        }

  defstruct [
    :game_id,
    :root_claim,
    :status,
    :created_at,
    :resolved_at,
    :l2_block_number,
    :starting_output_root,
    :disputed_output_root,
    claims: [],
    current_depth: 0
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:game_id]))
  end

  @doc """
  Creates a new dispute game challenging an output root.
  """
  @spec create_game(map()) :: {:ok, String.t()} | {:error, term()}
  def create_game(_params) do
    game_id = generate_game_id()
    opts = Map.put(params, :game_id, game_id)

    case GenServer.start(__MODULE__, opts, name: via_tuple(game_id)) do
      {:ok, _pid} -> {:ok, game_id}
      {:error, _reason} -> {:error, _reason}
    end
  end

  @doc """
  Makes a move in the dispute game by posting a claim.
  """
  @spec move(String.t(), non_neg_integer(), binary()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def move(game_id, parent_index, claim_data) do
    GenServer.call(via_tuple(game_id), {:move, parent_index, claim_data})
  end

  @doc """
  Attacks a claim by disputing its validity (moves left in game tree).
  """
  @spec attack(String.t(), non_neg_integer(), binary()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def attack(game_id, parent_index, claim_data) do
    move(game_id, parent_index, claim_data)
  end

  @doc """
  Defends a claim by disputing what it counters (moves right in game tree).
  """
  @spec defend(String.t(), non_neg_integer(), binary()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def defend(game_id, parent_index, claim_data) do
    # Defend means we agree with parent but disagree with grandparent
    GenServer.call(via_tuple(game_id), {:defend, parent_index, claim_data})
  end

  @doc """
  Steps through a single instruction when at max depth.
  This is the final step that determines the winner.
  """
  @spec step(String.t(), non_neg_integer(), binary(), binary()) ::
          {:ok, :valid | :invalid} | {:error, term()}
  def step(game_id, claim_index, prestate, proof) do
    GenServer.call(via_tuple(game_id), {:step, claim_index, prestate, proof})
  end

  @doc """
  Resolves the game after timeout or successful challenge.
  """
  @spec resolve(String.t()) :: {:ok, game_status()} | {:error, term()}
  def resolve(game_id) do
    GenServer.call(via_tuple(game_id), :resolve)
  end

  @doc """
  Gets the current state of a dispute game.
  """
  @spec get_state(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_state(game_id) do
    GenServer.call(via_tuple(game_id), :get_state)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting dispute game: #{opts.game_id}")

    root_claim = %{
      parent_index: nil,
      countered_by: nil,
      claimant: opts[:challenger],
      bond: calculate_bond(0),
      claim: opts[:disputed_output_root],
      # Root position
      position: 1,
      clock: @max_clock_duration
    }

    state = %__MODULE__{
      game_id: opts.game_id,
      root_claim: opts[:disputed_output_root],
      status: :in_progress,
      claims: [root_claim],
      created_at: DateTime.utc_now(),
      l2_block_number: opts[:l2_block_number],
      starting_output_root: opts[:starting_output_root],
      disputed_output_root: opts[:disputed_output_root],
      current_depth: 0
    }

    # Schedule game timeout
    Process.send_after(self(), :check_timeout, 60_000)

    {:ok, _state}
  end

  @impl true
  def handle_call({:move, parent_index, claim_data}, {from_pid, _}, _state) do
    case get_claim(state, parent_index) do
      nil ->
        {:reply, {:error, :parent_not_found}, state}

      parent_claim ->
        depth = calculate_depth(parent_claim.position)

        if depth >= @max_game_depth do
          {:reply, {:error, :max_depth_reached}, state}
        else
          new_claim = create_claim(parent_index, parent_claim, claim_data, from_pid, depth)
          claim_index = length(state.claims)

          new_claims = state.claims ++ [new_claim]

          new_state = %{
            state
            | claims: new_claims,
              current_depth: max(state.current_depth, depth)
          }

          Logger.info("Move #{claim_index} at depth #{depth} in game #{state.game_id}")

          {:reply, {:ok, claim_index}, new_state}
        end
    end
  end

  @impl true
  def handle_call({:defend, parent_index, claim_data}, {from_pid, _}, _state) do
    case get_claim(state, parent_index) do
      nil ->
        {:reply, {:error, :parent_not_found}, state}

      parent_claim ->
        # For defend, we need the grandparent
        case parent_claim.parent_index do
          nil ->
            {:reply, {:error, :cannot_defend_root}, state}

          _grandparent_index ->
            depth = calculate_depth(parent_claim.position)

            if depth >= @max_game_depth do
              {:reply, {:error, :max_depth_reached}, state}
            else
              # Position for defend move (right in tree)
              defend_position = parent_claim.position * 2 + 1

              new_claim = %{
                parent_index: parent_index,
                countered_by: nil,
                claimant: get_claimant(from_pid),
                bond: calculate_bond(depth),
                claim: claim_data,
                position: defend_position,
                clock: calculate_clock(parent_claim)
              }

              claim_index = length(state.claims)
              new_claims = state.claims ++ [new_claim]
              new_state = %{state | claims: new_claims}

              Logger.info("Defend move #{claim_index} at depth #{depth}")

              {:reply, {:ok, claim_index}, new_state}
            end
        end
    end
  end

  @impl true
  def handle_call({:step, claim_index, prestate, proof}, _from, _state) do
    case get_claim(state, claim_index) do
      nil ->
        {:reply, {:error, :claim_not_found}, state}

      claim ->
        depth = calculate_depth(claim.position)

        if depth < @max_game_depth do
          {:reply, {:error, :not_at_max_depth}, state}
        else
          # Verify the step proof
          case verify_step_proof(claim, prestate, proof, state) do
            {:ok, :valid} ->
              # Attacker was wrong
              Logger.info("Step proof valid - defender wins at claim #{claim_index}")
              {:reply, {:ok, :valid}, state}

            {:ok, :invalid} ->
              # Attacker was right
              Logger.info("Step proof invalid - attacker wins at claim #{claim_index}")
              {:reply, {:ok, :invalid}, state}

            {:error, _reason} = error ->
              Logger.error("Step verification failed: #{inspect(reason)}")
              {:reply, error, state}
          end
        end
    end
  end

  @impl true
  def handle_call(:resolve, _from, _state) do
    case resolve_game(state) do
      {:ok, status} ->
        new_state = %{state | status: status, resolved_at: DateTime.utc_now()}

        Logger.info("Game #{state.game_id} resolved: #{status}")

        {:reply, {:ok, status}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, _state) do
    {:reply, {:ok, _state}, state}
  end

  @impl true
  def handle_info(:check_timeout, _state) do
    # Check if any clocks have expired
    now = DateTime.utc_now()
    game_age = DateTime.diff(now, state.created_at)

    if game_age >= @game_duration do
      # Game has timed out - resolve based on current state
      {:ok, status} = resolve_game(state)

      new_state = %{state | status: status, resolved_at: now}

      Logger.info("Game #{state.game_id} timed out: #{status}")

      {:noreply, new_state}
    else
      # Check again in a minute
      Process.send_after(self(), :check_timeout, 60_000)
      {:noreply, state}
    end
  end

  # Private Functions

  defp via_tuple(game_id) do
    {:via, Registry, {ExWire.Layer2.DisputeGameRegistry, game_id}}
  end

  defp generate_game_id() do
    "dispute_" <> Base.encode16(:crypto.strong_rand_bytes(16))
  end

  defp get_claim(_state, index) when index >= 0 and index < length(state.claims) do
    Enum.at(state.claims, index)
  end

  defp get_claim(_state, _index), do: nil

  defp calculate_depth(position) do
    # Depth is log2 of position
    position
    |> :math.log2()
    |> Float.floor()
    |> round()
  end

  defp calculate_bond(depth) do
    # Bond doubles every 8 levels
    # Starting at 0.08 ETH
    # 0.08 ETH in wei
    base_bond = 80_000_000_000_000_000
    multiplier = :math.pow(2, div(depth, 8)) |> round()
    base_bond * multiplier
  end

  defp create_claim(parent_index, parent_claim, claim_data, from_pid, depth) do
    # Attack position (left in tree)
    attack_position = parent_claim.position * 2

    %{
      parent_index: parent_index,
      countered_by: nil,
      claimant: get_claimant(from_pid),
      bond: calculate_bond(depth),
      claim: claim_data,
      position: attack_position,
      clock: calculate_clock(parent_claim)
    }
  end

  defp get_claimant(_from_pid) do
    # In production, would extract actual address from caller
    <<0::160>>
  end

  defp calculate_clock(parent_claim) do
    # Each player gets half the remaining time
    div(parent_claim.clock, 2)
  end

  defp verify_step_proof(claim, prestate, proof, _state) do
    # This would run the MIPS VM step function
    # For now, simulate verification

    cond do
      byte_size(prestate) != 32 ->
        {:error, :invalid_prestate}

      byte_size(proof) < 100 ->
        {:error, :invalid_proof}

      # Check if we're above or below split depth
      calculate_depth(claim.position) < @split_depth ->
        # Block-level bisection
        verify_block_transition(claim, prestate, proof, state)

      true ->
        # Instruction-level bisection
        verify_instruction_step(claim, prestate, proof, state)
    end
  end

  defp verify_block_transition(_claim, _prestate, _proof, _state) do
    # Verify state transition between blocks
    # In production, would check actual state roots
    {:ok, Enum.random([:valid, :invalid])}
  end

  defp verify_instruction_step(_claim, _prestate, _proof, _state) do
    # Run single MIPS instruction
    # In production, would use actual MIPS VM
    {:ok, Enum.random([:valid, :invalid])}
  end

  defp resolve_game(_state) do
    # Determine winner based on game tree
    # The uncountered claim closest to the root wins

    uncountered =
      Enum.filter(state.claims, fn claim ->
        claim.countered_by == nil
      end)

    if Enum.empty?(uncountered) do
      {:ok, :draw}
    else
      # Find the uncountered claim with minimum depth
      winner_claim =
        Enum.min_by(uncountered, fn claim ->
          calculate_depth(claim.position)
        end)

      # If root claim is uncountered, defender wins
      # Otherwise challenger wins
      if winner_claim == hd(state.claims) do
        {:ok, :challenger_wins}
      else
        {:ok, :defender_wins}
      end
    end
  end
end
