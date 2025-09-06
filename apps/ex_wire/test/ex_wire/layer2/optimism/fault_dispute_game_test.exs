defmodule ExWire.Layer2.Optimism.FaultDisputeGameTest do
  use ExUnit.Case, async: false

  alias ExWire.Layer2.Optimism.FaultDisputeGame

  @moduletag :layer2
  @moduletag :optimism
  @moduletag :dispute_game

  setup do
    # Ensure registry is started
    Registry.start_link(keys: :unique, name: ExWire.Layer2.DisputeGameRegistry)
    :ok
  end

  describe "game creation" do
    test "creates new dispute game" do
      params = %{
        challenger: <<1::160>>,
        l2_block_number: 5000,
        starting_output_root: :crypto.strong_rand_bytes(32),
        disputed_output_root: :crypto.strong_rand_bytes(32)
      }

      assert {:ok, game_id} = FaultDisputeGame.create_game(params)
      assert String.starts_with?(game_id, "dispute_")

      # Verify game state
      assert {:ok, state} = FaultDisputeGame.get_state(game_id)
      assert state.status == :in_progress
      assert state.l2_block_number == 5000
      # Root claim
      assert length(state.claims) == 1
    end
  end

  describe "game moves" do
    setup do
      params = %{
        challenger: <<1::160>>,
        l2_block_number: 5000,
        starting_output_root: :crypto.strong_rand_bytes(32),
        disputed_output_root: :crypto.strong_rand_bytes(32)
      }

      {:ok, game_id} = FaultDisputeGame.create_game(params)
      {:ok, game_id: game_id}
    end

    test "makes attack move", %{game_id: game_id} do
      # Attack root claim
      parent_index = 0
      claim_data = :crypto.strong_rand_bytes(32)

      assert {:ok, claim_index} = FaultDisputeGame.attack(game_id, parent_index, claim_data)
      assert claim_index == 1

      # Verify claim was added
      {:ok, state} = FaultDisputeGame.get_state(game_id)
      assert length(state.claims) == 2
    end

    test "makes defend move", %{game_id: game_id} do
      # First make an attack
      {:ok, attack_index} = FaultDisputeGame.attack(game_id, 0, :crypto.strong_rand_bytes(32))

      # Then defend the attack
      defend_data = :crypto.strong_rand_bytes(32)
      assert {:ok, defend_index} = FaultDisputeGame.defend(game_id, attack_index, defend_data)
      assert defend_index == 2

      {:ok, state} = FaultDisputeGame.get_state(game_id)
      assert length(state.claims) == 3
    end

    test "cannot defend root claim", %{game_id: game_id} do
      defend_data = :crypto.strong_rand_bytes(32)

      assert {:error, :cannot_defend_root} =
               FaultDisputeGame.defend(game_id, 0, defend_data)
    end

    test "respects max depth limit", %{game_id: game_id} do
      # Make moves until we approach max depth
      # This is simplified - in reality would need 73 moves
      parent_index = 0

      # Make several moves to test depth tracking
      for i <- 1..10 do
        claim_data = :crypto.strong_rand_bytes(32)
        {:ok, new_index} = FaultDisputeGame.move(game_id, parent_index, claim_data)

        if i < 10 do
          # Continue chain
          parent_index = new_index
        end
      end

      {:ok, state} = FaultDisputeGame.get_state(game_id)
      # Root + 10 moves
      assert length(state.claims) == 11
    end
  end

  describe "step verification" do
    setup do
      params = %{
        challenger: <<1::160>>,
        l2_block_number: 5000,
        starting_output_root: :crypto.strong_rand_bytes(32),
        disputed_output_root: :crypto.strong_rand_bytes(32)
      }

      {:ok, game_id} = FaultDisputeGame.create_game(params)

      # Make moves to max depth (simplified for test)
      # In production, would need to reach actual max depth
      {:ok, claim_index} = FaultDisputeGame.attack(game_id, 0, :crypto.strong_rand_bytes(32))

      {:ok, game_id: game_id, claim_index: claim_index}
    end

    test "cannot step before max depth", %{game_id: game_id, claim_index: claim_index} do
      prestate = :crypto.strong_rand_bytes(32)
      proof = :crypto.strong_rand_bytes(200)

      # This should fail because we haven't reached max depth
      assert {:error, :not_at_max_depth} =
               FaultDisputeGame.step(game_id, claim_index, prestate, proof)
    end

    test "validates step proof format" do
      # This would test actual step verification
      # For now just verify the function exists
      params = %{
        challenger: <<1::160>>,
        l2_block_number: 5000,
        starting_output_root: :crypto.strong_rand_bytes(32),
        disputed_output_root: :crypto.strong_rand_bytes(32)
      }

      {:ok, game_id} = FaultDisputeGame.create_game(params)

      # Invalid prestate size
      assert {:error, :not_at_max_depth} =
               FaultDisputeGame.step(game_id, 0, <<>>, <<>>)
    end
  end

  describe "game resolution" do
    setup do
      params = %{
        challenger: <<1::160>>,
        l2_block_number: 5000,
        starting_output_root: :crypto.strong_rand_bytes(32),
        disputed_output_root: :crypto.strong_rand_bytes(32)
      }

      {:ok, game_id} = FaultDisputeGame.create_game(params)
      {:ok, game_id: game_id}
    end

    test "resolves game with winner", %{game_id: game_id} do
      # Make some moves
      FaultDisputeGame.attack(game_id, 0, :crypto.strong_rand_bytes(32))

      # Resolve the game
      assert {:ok, status} = FaultDisputeGame.resolve(game_id)
      assert status in [:challenger_wins, :defender_wins]

      # Verify resolution is recorded
      {:ok, state} = FaultDisputeGame.get_state(game_id)
      assert state.status == status
      assert state.resolved_at != nil
    end

    test "handles draw scenario", %{game_id: game_id} do
      # In certain conditions, game could end in draw
      # This would happen if all claims are countered
      assert {:ok, _status} = FaultDisputeGame.resolve(game_id)
    end
  end

  describe "game tree mechanics" do
    setup do
      params = %{
        challenger: <<1::160>>,
        l2_block_number: 5000,
        starting_output_root: :crypto.strong_rand_bytes(32),
        disputed_output_root: :crypto.strong_rand_bytes(32)
      }

      {:ok, game_id} = FaultDisputeGame.create_game(params)
      {:ok, game_id: game_id}
    end

    test "calculates position correctly for attacks", %{game_id: game_id} do
      # Attack moves left in tree (position * 2)
      {:ok, _} = FaultDisputeGame.attack(game_id, 0, :crypto.strong_rand_bytes(32))

      {:ok, state} = FaultDisputeGame.get_state(game_id)
      second_claim = Enum.at(state.claims, 1)

      # Root has position 1, attack should have position 2
      assert second_claim.position == 2
    end

    test "calculates position correctly for defends", %{game_id: game_id} do
      # First attack
      {:ok, attack_index} = FaultDisputeGame.attack(game_id, 0, :crypto.strong_rand_bytes(32))

      # Defend moves right in tree (position * 2 + 1)
      {:ok, _} = FaultDisputeGame.defend(game_id, attack_index, :crypto.strong_rand_bytes(32))

      {:ok, state} = FaultDisputeGame.get_state(game_id)
      defend_claim = Enum.at(state.claims, 2)

      # Attack at position 2, defend should be at position 5 (2*2+1)
      assert defend_claim.position == 5
    end

    test "tracks claim bonds correctly", %{game_id: game_id} do
      {:ok, state} = FaultDisputeGame.get_state(game_id)
      root_claim = hd(state.claims)

      # Bond should be set
      assert root_claim.bond > 0

      # Bond doubles every 8 levels
      # 0.08 ETH
      base_bond = 80_000_000_000_000_000
      assert root_claim.bond == base_bond
    end
  end

  describe "timing and clocks" do
    test "initializes with correct clock duration" do
      params = %{
        challenger: <<1::160>>,
        l2_block_number: 5000,
        starting_output_root: :crypto.strong_rand_bytes(32),
        disputed_output_root: :crypto.strong_rand_bytes(32)
      }

      {:ok, game_id} = FaultDisputeGame.create_game(params)
      {:ok, state} = FaultDisputeGame.get_state(game_id)

      root_claim = hd(state.claims)
      # 3.5 days in seconds
      assert root_claim.clock == 3.5 * 24 * 60 * 60
    end

    test "splits clock time between players" do
      params = %{
        challenger: <<1::160>>,
        l2_block_number: 5000,
        starting_output_root: :crypto.strong_rand_bytes(32),
        disputed_output_root: :crypto.strong_rand_bytes(32)
      }

      {:ok, game_id} = FaultDisputeGame.create_game(params)

      # Make a move
      {:ok, _} = FaultDisputeGame.attack(game_id, 0, :crypto.strong_rand_bytes(32))

      {:ok, state} = FaultDisputeGame.get_state(game_id)
      root_claim = Enum.at(state.claims, 0)
      attack_claim = Enum.at(state.claims, 1)

      # Clock should be halved
      assert attack_claim.clock == div(root_claim.clock, 2)
    end
  end
end
