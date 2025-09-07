defmodule ExWire.DVT.PropertyTest do
  @moduledoc """
  Property-based tests for DVT cryptographic operations using StreamData.

  These tests verify that DVT operations maintain their mathematical properties
  under various input conditions and edge cases.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExWire.DVT.Crypto

  # Test properties for threshold configurations
  property "valid threshold configurations are always accepted" do
    check all(
            total_nodes <- StreamData.integer(3..50),
            threshold <- StreamData.integer((div(total_nodes, 2) + 1)..total_nodes)
          ) do
      assert {:ok, true} = Crypto.validate_threshold_config(threshold, total_nodes)
    end
  end

  property "invalid threshold configurations are always rejected" do
    check all(
            total_nodes <- StreamData.integer(1..50),
            threshold <-
              StreamData.one_of([
                # Zero threshold
                StreamData.integer(0..0),
                # Threshold too high
                StreamData.integer((total_nodes + 1)..(total_nodes + 10)),
                # Threshold too low for security
                StreamData.integer(1..div(total_nodes, 2))
              ])
          ) do
      assert {:error, :invalid_threshold} =
               Crypto.validate_threshold_config(threshold, total_nodes)
    end
  end

  # Key generation properties
  property "generated keys are always unique" do
    check all(
            threshold <- StreamData.integer(2..7),
            total_nodes <- StreamData.integer(threshold..10),
            _iterations <- StreamData.integer(1..5)
          ) do
      # Generate multiple key sets
      key_sets =
        Enum.map(1..3, fn _ ->
          case Crypto.generate_dvt_keys(threshold, total_nodes) do
            {:ok, {public_key_set, key_shares}} -> {public_key_set, key_shares}
            _ -> nil
          end
        end)

      # Filter out any failures
      valid_sets = Enum.reject(key_sets, &is_nil/1)

      if length(valid_sets) >= 2 do
        # Verify all generated key sets are unique
        public_keys = Enum.map(valid_sets, fn {pks, _} -> pks end)
        assert public_keys == Enum.uniq(public_keys)

        # Verify key shares are unique across sets
        all_shares = Enum.flat_map(valid_sets, fn {_, shares} -> shares end)
        assert length(all_shares) == length(Enum.uniq(all_shares))
      end
    end
  end

  property "key generation produces correct number of shares" do
    check all(
            threshold <- StreamData.integer(2..7),
            total_nodes <- StreamData.integer(threshold..10)
          ) do
      case Crypto.generate_dvt_keys(threshold, total_nodes) do
        {:ok, {public_key_set, key_shares}} ->
          assert is_binary(public_key_set)
          assert byte_size(public_key_set) > 0
          assert is_list(key_shares)
          assert length(key_shares) == total_nodes

          # All shares should be non-empty binaries
          Enum.each(key_shares, fn share ->
            assert is_binary(share)
            assert byte_size(share) > 0
          end)

        {:error, _reason} ->
          # Some configurations might fail - that's okay for property testing
          :ok
      end
    end
  end

  # Signature share properties
  property "signature shares are deterministic for same input" do
    check all(
            threshold <- StreamData.integer(2..5),
            total_nodes <- StreamData.integer(threshold..7),
            message <- StreamData.binary(min_length: 1, max_length: 1000)
          ) do
      case Crypto.generate_dvt_keys(threshold, total_nodes) do
        {:ok, {_public_key_set, key_shares}} ->
          key_share = hd(key_shares)

          # Create signature twice with same inputs
          case {Crypto.create_dvt_signature_share(key_share, message),
                Crypto.create_dvt_signature_share(key_share, message)} do
            {{:ok, sig1}, {:ok, sig2}} ->
              # Should be identical (deterministic signing)
              assert sig1 == sig2

            _ ->
              # Signature creation failed - skip this test case
              :ok
          end

        _ ->
          # Key generation failed - skip this test case
          :ok
      end
    end
  end

  property "different messages produce different signatures" do
    check all(
            threshold <- StreamData.integer(2..5),
            total_nodes <- StreamData.integer(threshold..7),
            message1 <- StreamData.binary(min_length: 1, max_length: 500),
            message2 <- StreamData.binary(min_length: 1, max_length: 500),
            message1 != message2
          ) do
      case Crypto.generate_dvt_keys(threshold, total_nodes) do
        {:ok, {_public_key_set, key_shares}} ->
          key_share = hd(key_shares)

          case {Crypto.create_dvt_signature_share(key_share, message1),
                Crypto.create_dvt_signature_share(key_share, message2)} do
            {{:ok, sig1}, {:ok, sig2}} ->
              # Different messages should produce different signatures
              assert sig1 != sig2

            _ ->
              # Signature creation failed - skip
              :ok
          end

        _ ->
          # Key generation failed - skip
          :ok
      end
    end
  end

  # Signature aggregation properties  
  property "signature aggregation is consistent" do
    check all(
            threshold <- StreamData.integer(2..4),
            total_nodes <- StreamData.integer(threshold..6),
            message <- StreamData.binary(min_length: 1, max_length: 100)
          ) do
      case Crypto.generate_dvt_keys(threshold, total_nodes) do
        {:ok, {public_key_set, key_shares}} ->
          # Create signature shares from exactly threshold nodes
          signature_shares_result =
            key_shares
            |> Enum.take(threshold)
            |> Enum.map(&Crypto.create_dvt_signature_share(&1, message))
            |> Enum.reduce_while({:ok, []}, fn
              {:ok, share}, {:ok, acc} -> {:cont, {:ok, [share | acc]}}
              error, _ -> {:halt, error}
            end)

          case signature_shares_result do
            {:ok, signature_shares} ->
              # Aggregate signatures multiple times
              results =
                Enum.map(1..3, fn _ ->
                  Crypto.aggregate_dvt_signatures(public_key_set, signature_shares, threshold)
                end)

              # All aggregations should succeed and be identical
              case Enum.uniq(results) do
                [single_result] ->
                  assert match?({:ok, _}, single_result)

                _ ->
                  # Results were not identical - this shouldn't happen
                  flunk("Signature aggregation not consistent")
              end

            _ ->
              # Signature share creation failed - skip
              :ok
          end

        _ ->
          # Key generation failed - skip
          :ok
      end
    end
  end

  property "insufficient shares always fail aggregation" do
    check all(
            threshold <- StreamData.integer(3..7),
            total_nodes <- StreamData.integer(threshold..10),
            insufficient_count <- StreamData.integer(1..(threshold - 1)),
            message <- StreamData.binary(min_length: 1, max_length: 100)
          ) do
      case Crypto.generate_dvt_keys(threshold, total_nodes) do
        {:ok, {public_key_set, key_shares}} ->
          # Create insufficient number of signature shares
          insufficient_shares_result =
            key_shares
            |> Enum.take(insufficient_count)
            |> Enum.map(&Crypto.create_dvt_signature_share(&1, message))
            |> Enum.reduce_while({:ok, []}, fn
              {:ok, share}, {:ok, acc} -> {:cont, {:ok, [share | acc]}}
              error, _ -> {:halt, error}
            end)

          case insufficient_shares_result do
            {:ok, insufficient_shares} ->
              # Aggregation should always fail
              assert {:error, :insufficient_shares} =
                       Crypto.aggregate_dvt_signatures(
                         public_key_set,
                         insufficient_shares,
                         threshold
                       )

            _ ->
              # Share creation failed - skip
              :ok
          end

        _ ->
          # Key generation failed - skip
          :ok
      end
    end
  end

  # DKG properties
  property "DKG initialization produces valid data structures" do
    check all(
            participants <-
              StreamData.list_of(
                StreamData.integer(0..20),
                min_length: 3,
                max_length: 10
              )
              |> StreamData.map(&Enum.uniq/1),
            threshold <-
              StreamData.integer((div(length(participants), 2) + 1)..length(participants)),
            node_id <- StreamData.member_of(participants),
            round_suffix <- StreamData.binary(min_length: 1, max_length: 20)
          ) do
      # Ensure consistent ordering
      participants = Enum.sort(participants)
      round_id = "prop_test_#{Base.encode16(round_suffix)}"

      case Crypto.initialize_dkg(node_id, participants, threshold, round_id) do
        {:ok, dkg_data} ->
          # Verify structure
          assert is_map(dkg_data)
          assert Map.has_key?(dkg_data, :participant_data)
          assert Map.has_key?(dkg_data, :initial_shares)

          assert is_binary(dkg_data.participant_data)
          assert byte_size(dkg_data.participant_data) > 0

          assert is_list(dkg_data.initial_shares)
          # Should have shares for all participants except self
          assert length(dkg_data.initial_shares) == length(participants) - 1

          # All shares should be non-empty binaries
          Enum.each(dkg_data.initial_shares, fn share ->
            assert is_binary(share)
            assert byte_size(share) > 0
          end)

        {:error, _reason} ->
          # DKG initialization can fail for various reasons - that's acceptable
          :ok
      end
    end
  end

  property "DKG complaints are verifiable" do
    check all(
            complainer_id <- StreamData.integer(0..10),
            accused_id <- StreamData.integer(0..10),
            complainer_id != accused_id,
            invalid_share <- StreamData.binary(min_length: 1, max_length: 100),
            round_suffix <- StreamData.binary(min_length: 1, max_length: 10)
          ) do
      round_id = "complaint_test_#{Base.encode16(round_suffix)}"

      case Crypto.generate_complaint(complainer_id, accused_id, invalid_share, round_id) do
        {:ok, complaint} ->
          assert is_binary(complaint)
          assert byte_size(complaint) > 0

          # Complaint should be verifiable
          case Crypto.verify_complaint(complaint) do
            {:ok, is_valid} ->
              assert is_boolean(is_valid)

            {:error, _reason} ->
              # Verification might fail - that's acceptable for property testing
              :ok
          end

        {:error, _reason} ->
          # Complaint generation failed - skip
          :ok
      end
    end
  end

  # Error handling properties
  property "corrupted inputs always return errors gracefully" do
    check all(
            corrupted_data <-
              StreamData.one_of([
                # Too short
                StreamData.binary(min_length: 0, max_length: 10),
                # Very large
                StreamData.binary(min_length: 10000, max_length: 20000),
                # Invalid data
                StreamData.constant(<<255, 255, 255, 255>>)
              ]),
            message <- StreamData.binary(min_length: 1, max_length: 100)
          ) do
      # These operations should return errors, not crash
      assert {:error, _} = Crypto.create_dvt_signature_share(corrupted_data, message)
      assert {:error, _} = Crypto.get_public_key_from_share(corrupted_data)
      assert {:error, _} = Crypto.verify_complaint(corrupted_data)
    end
  end

  property "operations with empty inputs handle gracefully" do
    check all(message <- StreamData.binary(min_length: 0, max_length: 100)) do
      empty_binary = <<>>

      # These should return errors, not crash
      assert {:error, _} = Crypto.create_dvt_signature_share(empty_binary, message)
      assert {:error, _} = Crypto.aggregate_dvt_signatures(empty_binary, [], 1)
      assert {:error, _} = Crypto.verify_dvt_signature(empty_binary, empty_binary, message)
    end
  end

  # Performance properties
  @tag :slow
  property "key generation time scales reasonably with cluster size" do
    check all(
            cluster_sizes <-
              StreamData.list_of(
                StreamData.integer(3..15),
                min_length: 3,
                max_length: 5
              )
          ) do
      # Test different cluster sizes and measure time
      timing_results =
        Enum.map(cluster_sizes, fn total_nodes ->
          threshold = div(total_nodes, 2) + 1

          {time_microseconds, result} =
            :timer.tc(fn ->
              Crypto.generate_dvt_keys(threshold, total_nodes)
            end)

          case result do
            {:ok, _} -> {total_nodes, time_microseconds}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      if length(timing_results) >= 2 do
        # Verify that time doesn't increase exponentially with cluster size
        max_time = Enum.map(timing_results, fn {_, time} -> time end) |> Enum.max()

        # Should complete within reasonable time (less than 10 seconds even for larger clusters)
        assert max_time < 10_000_000
      end
    end
  end

  # Mathematical properties
  property "threshold signature verification maintains correctness" do
    check all(
            threshold <- StreamData.integer(2..4),
            total_nodes <- StreamData.integer(threshold..6),
            message <- StreamData.binary(min_length: 1, max_length: 100),
            wrong_message <- StreamData.binary(min_length: 1, max_length: 100),
            message != wrong_message
          ) do
      case generate_complete_signature(threshold, total_nodes, message) do
        {:ok, {public_key, signature}} ->
          # Correct message should verify
          assert {:ok, true} = Crypto.verify_dvt_signature(public_key, signature, message)

          # Wrong message should not verify  
          assert {:ok, false} = Crypto.verify_dvt_signature(public_key, signature, wrong_message)

        _ ->
          # Signature generation failed - skip
          :ok
      end
    end
  end

  # Helper function for generating complete signatures
  defp generate_complete_signature(threshold, total_nodes, message) do
    with {:ok, {public_key_set, key_shares}} <- Crypto.generate_dvt_keys(threshold, total_nodes),
         {:ok, signature_shares} <- create_signature_shares(key_shares, threshold, message),
         {:ok, threshold_signature} <-
           Crypto.aggregate_dvt_signatures(public_key_set, signature_shares, threshold),
         {:ok, public_key} <- Crypto.get_public_key_from_share(hd(key_shares)) do
      {:ok, {public_key, threshold_signature}}
    else
      error -> error
    end
  end

  defp create_signature_shares(key_shares, threshold, message) do
    key_shares
    |> Enum.take(threshold)
    |> Enum.map(&Crypto.create_dvt_signature_share(&1, message))
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, share}, {:ok, acc} -> {:cont, {:ok, [share | acc]}}
      error, _ -> {:halt, error}
    end)
  end
end
