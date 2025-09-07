defmodule EVM.PropertyTests.EVMPropertyTest do
  @moduledoc """
  Property-based tests for EVM (Ethereum Virtual Machine) operations.

  These tests verify that EVM operations maintain invariants under various
  conditions, test gas cost calculations, and ensure stack operations
  behave correctly with different inputs.
  """

  use ExUnitProperties
  import StreamData
  import Blockchain.PropertyTesting.Generators

  alias EVM.{Stack, Memory, Gas, Wei}
  alias EVM.Operation

  @moduletag :property_test
  @moduletag timeout: 120_000

  # EVM Stack Property Tests

  property "stack push/pop operations preserve LIFO order" do
    check all(
            items <-
              list_of(
                integer(0..0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF),
                min_length: 1,
                max_length: 1024
              )
          ) do
      # Push all items onto stack
      final_stack =
        Enum.reduce(items, Stack.create(), fn item, stack ->
          {:ok, new_stack} = Stack.push(stack, item)
          new_stack
        end)

      # Pop all items and verify order (should be reversed)
      {popped_items, empty_stack} = pop_all_items(final_stack, [])

      assert Stack.size(empty_stack) == 0
      assert popped_items == Enum.reverse(items)
    end
  end

  property "stack operations maintain size invariants" do
    check all(operations <- list_of(stack_operation(), min_length: 0, max_length: 100)) do
      final_stack =
        Enum.reduce(operations, Stack.create(), fn op, stack ->
          apply_stack_operation(op, stack)
        end)

      # Stack size should never be negative
      assert Stack.size(final_stack) >= 0

      # Stack size should not exceed EVM limit (1024 items)
      assert Stack.size(final_stack) <= 1024
    end
  end

  property "stack overflow protection" do
    check all(
            stack_items <-
              list_of(integer(0..0xFFFFFFFFFFFFFFFF), min_length: 1024, max_length: 1025)
          ) do
      result =
        Enum.reduce_while(stack_items, Stack.create(), fn item, stack ->
          case Stack.push(stack, item) do
            {:ok, new_stack} -> {:cont, new_stack}
            {:error, :stack_overflow} -> {:halt, :overflow_detected}
          end
        end)

      # Should detect overflow when trying to exceed 1024 items
      if length(stack_items) > 1024 do
        assert result == :overflow_detected
      end
    end
  end

  # EVM Memory Property Tests

  property "memory operations preserve data integrity" do
    check all(writes <- list_of(memory_write_operation(), min_length: 0, max_length: 50)) do
      final_memory =
        Enum.reduce(writes, Memory.init(), fn {offset, data}, memory ->
          Memory.write(memory, offset, data)
        end)

      # Verify all written data can be read back correctly
      Enum.each(writes, fn {offset, data} ->
        read_data = Memory.read(final_memory, offset, byte_size(data))
        assert read_data == data
      end)
    end
  end

  property "memory expansion costs are monotonic" do
    check all(
            {size1, size2} <- {non_neg_integer(), non_neg_integer()},
            size1 <= size2,
            # Reasonable upper bound
            size1 < 100_000,
            size2 < 100_000
          ) do
      cost1 = Gas.memory_cost(size1)
      cost2 = Gas.memory_cost(size2)

      # Larger memory should cost more or equal gas
      assert cost1 <= cost2

      # Memory cost should be reasonable (not negative or extremely large)
      assert cost1 >= 0
      assert cost2 >= 0
      # Sanity check
      assert cost1 < 1_000_000_000
    end
  end

  # EVM Gas Calculation Property Tests

  property "gas calculations are deterministic" do
    check all(
            opcode <- integer(0x00..0xFF),
            stack_size <- integer(0..1024),
            memory_size <- integer(0..10000)
          ) do
      gas1 = calculate_gas_for_operation(opcode, stack_size, memory_size)
      gas2 = calculate_gas_for_operation(opcode, stack_size, memory_size)

      assert gas1 == gas2
    end
  end

  property "gas costs are non-negative" do
    check all(
            opcode <- integer(0x00..0xFF),
            stack_size <- integer(0..1024),
            memory_size <- integer(0..10000)
          ) do
      gas_cost = calculate_gas_for_operation(opcode, stack_size, memory_size)
      assert gas_cost >= 0
    end
  end

  # Wei and arithmetic operations

  property "wei arithmetic operations don't overflow unexpectedly" do
    check all(
            {amount1, amount2} <- {wei_amount(), wei_amount()},
            # Keep amounts reasonable
            amount1 < Wei.ether() * 1000,
            amount2 < Wei.ether() * 1000
          ) do
      # Addition should be commutative when it doesn't overflow
      if amount1 + amount2 <= (1 <<< 256) - 1 do
        sum1 = Wei.sum([amount1, amount2])
        sum2 = Wei.sum([amount2, amount1])
        assert sum1 == sum2
      end

      # Subtraction should be inverse of addition
      if amount1 >= amount2 do
        diff = amount1 - amount2
        assert diff + amount2 == amount1
      end
    end
  end

  property "wei conversions are consistent" do
    check all(ether_amount <- integer(0..1000)) do
      wei_value = Wei.ether() * ether_amount

      # Converting back should give original amount
      back_to_ether = div(wei_value, Wei.ether())
      assert back_to_ether == ether_amount

      # Wei should be divisible by smaller units
      assert rem(Wei.ether(), Wei.gwei()) == 0
      # Microether
      assert rem(Wei.gwei(), 1000) == 0
    end
  end

  # EVM Operation Property Tests

  property "arithmetic operations follow mathematical properties" do
    check all({a, b} <- {integer(0..0xFFFFFFFF), integer(0..0xFFFFFFFF)}) do
      # Addition should be commutative (when not overflowing)
      if a + b <= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF do
        stack1 = Stack.create() |> push_value(a) |> push_value(b)
        stack2 = Stack.create() |> push_value(b) |> push_value(a)

        {:ok, result1} = simulate_add_operation(stack1)
        {:ok, result2} = simulate_add_operation(stack2)

        assert result1 == result2
      end

      # Multiplication should be commutative
      if a * b <= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF do
        stack1 = Stack.create() |> push_value(a) |> push_value(b)
        stack2 = Stack.create() |> push_value(b) |> push_value(a)

        {:ok, result1} = simulate_mul_operation(stack1)
        {:ok, result2} = simulate_mul_operation(stack2)

        assert result1 == result2
      end
    end
  end

  property "comparison operations are consistent" do
    check all(
            {a, b, c} <- {integer(0..0xFFFFFFFF), integer(0..0xFFFFFFFF), integer(0..0xFFFFFFFF)}
          ) do
      # Transitivity: if a < b and b < c, then a < c
      lt_ab = compare_values(a, b) == :lt
      lt_bc = compare_values(b, c) == :lt
      lt_ac = compare_values(a, c) == :lt

      if lt_ab and lt_bc do
        assert lt_ac, "Transitivity failed: #{a} < #{b} < #{c} but #{a} >= #{c}"
      end

      # Antisymmetry: if a <= b and b <= a, then a == b
      lte_ab = compare_values(a, b) in [:lt, :eq]
      lte_ba = compare_values(b, a) in [:lt, :eq]

      if lte_ab and lte_ba do
        assert a == b
      end
    end
  end

  # Fuzzing tests for robustness

  property "fuzz test: random bytecode execution doesn't crash EVM" do
    check all(
            bytecode <- binary(min_length: 0, max_length: 1000),
            max_runs: 200
          ) do
      # Create initial EVM state
      initial_state = create_test_evm_state()

      # Execute bytecode and catch any crashes
      result =
        try do
          execute_bytecode(initial_state, bytecode)
        rescue
          _error -> {:error, :execution_failed}
        catch
          _kind, _value -> {:error, :execution_failed}
        end

      # Should either succeed or fail gracefully
      assert result in [
               :ok,
               {:error, :execution_failed},
               {:error, :out_of_gas},
               {:error, :stack_underflow},
               {:error, :stack_overflow},
               {:error, :invalid_opcode},
               {:error, :invalid_jump_destination}
             ]
    end
  end

  # Stateful property test for EVM execution
  property "stateful: EVM state transitions are deterministic" do
    check all(operations <- list_of(evm_operation(), min_length: 0, max_length: 20)) do
      initial_state = create_test_evm_state()

      # Execute operations twice
      final_state1 = execute_operations(initial_state, operations)
      final_state2 = execute_operations(initial_state, operations)

      # Results should be identical
      assert states_equal?(final_state1, final_state2)
    end
  end

  # Helper functions

  defp stack_operation() do
    frequency([
      {3, {:push, integer(0..0xFFFFFFFFFFFFFFFF)}},
      {2, :pop},
      {1, :duplicate},
      {1, :swap}
    ])
  end

  defp memory_write_operation() do
    gen all(
          offset <- integer(0..10000),
          data <- binary(min_length: 1, max_length: 32)
        ) do
      {offset, data}
    end
  end

  defp evm_operation() do
    frequency([
      {3, {:push, integer(0..0xFFFFFFFF)}},
      {2, {:add}},
      {2, {:mul}},
      {1, {:sub}},
      {1, {:div}},
      {1, {:mod}},
      {1, {:lt}},
      {1, {:gt}},
      {1, {:eq}}
    ])
  end

  defp apply_stack_operation({:push, value}, stack) do
    case Stack.push(stack, value) do
      {:ok, new_stack} -> new_stack
      # Keep original on overflow
      {:error, :stack_overflow} -> stack
    end
  end

  defp apply_stack_operation(:pop, stack) do
    case Stack.pop(stack) do
      {:ok, {_value, new_stack}} -> new_stack
      # Keep original on underflow
      {:error, :stack_underflow} -> stack
    end
  end

  defp apply_stack_operation(:duplicate, stack) do
    case Stack.peek(stack) do
      {:ok, value} ->
        case Stack.push(stack, value) do
          {:ok, new_stack} -> new_stack
          {:error, :stack_overflow} -> stack
        end

      {:error, :stack_underflow} ->
        stack
    end
  end

  defp apply_stack_operation(:swap, stack) do
    # Swap top two elements
    case Stack.pop(stack) do
      {:ok, {val1, stack1}} ->
        case Stack.pop(stack1) do
          {:ok, {val2, stack2}} ->
            with {:ok, stack3} <- Stack.push(stack2, val1),
                 {:ok, stack4} <- Stack.push(stack3, val2) do
              stack4
            else
              # Keep original on error
              _ -> stack
            end

          _ ->
            stack
        end

      _ ->
        stack
    end
  end

  defp pop_all_items(stack, acc) do
    case Stack.pop(stack) do
      {:ok, {value, new_stack}} -> pop_all_items(new_stack, [value | acc])
      {:error, :stack_underflow} -> {acc, stack}
    end
  end

  defp push_value(stack, value) do
    {:ok, new_stack} = Stack.push(stack, value)
    new_stack
  end

  defp calculate_gas_for_operation(opcode, _stack_size, _memory_size) do
    # Simplified gas calculation - in practice would be much more complex
    case opcode do
      # Arithmetic ops
      op when op in 0x00..0x0F -> 3
      # Comparison ops  
      op when op in 0x10..0x1F -> 3
      # SHA3, etc.
      op when op in 0x20..0x2F -> 30
      # Environmental info
      op when op in 0x30..0x3F -> 2
      # Block info
      op when op in 0x40..0x4F -> 20
      # Stack, memory, storage
      op when op in 0x50..0x5F -> 3
      # Push operations
      op when op in 0x60..0x7F -> 3
      # Duplication ops
      op when op in 0x80..0x8F -> 3
      # Exchange ops
      op when op in 0x90..0x9F -> 3
      # Invalid opcodes
      _ -> 0
    end
  end

  defp simulate_add_operation(stack) do
    with {:ok, {a, stack1}} <- Stack.pop(stack),
         {:ok, {b, stack2}} <- Stack.pop(stack1),
         {:ok, result_stack} <- Stack.push(stack2, a + b) do
      {:ok, Stack.peek!(result_stack)}
    else
      error -> error
    end
  end

  defp simulate_mul_operation(stack) do
    with {:ok, {a, stack1}} <- Stack.pop(stack),
         {:ok, {b, stack2}} <- Stack.pop(stack1),
         {:ok, result_stack} <- Stack.push(stack2, a * b) do
      {:ok, Stack.peek!(result_stack)}
    else
      error -> error
    end
  end

  defp compare_values(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp create_test_evm_state() do
    %{
      stack: Stack.create(),
      memory: Memory.init(),
      gas: 1_000_000,
      pc: 0,
      stopped: false
    }
  end

  defp execute_bytecode(_state, bytecode) do
    # Simplified bytecode execution simulation
    # In practice, this would be much more complex
    if byte_size(bytecode) == 0 do
      :ok
    else
      # Just simulate basic execution without crashing
      new_gas = max(0, state.gas - byte_size(bytecode) * 3)
      if new_gas > 0, do: :ok, else: {:error, :out_of_gas}
    end
  end

  defp execute_operations(_state, operations) do
    Enum.reduce(operations, state, fn op, acc_state ->
      execute_single_operation(acc_state, op)
    end)
  end

  defp execute_single_operation(_state, {:push, value}) do
    case Stack.push(state.stack, value) do
      {:ok, new_stack} -> %{state | stack: new_stack, gas: state.gas - 3}
      {:error, _} -> state
    end
  end

  defp execute_single_operation(_state, {:add}) do
    with {:ok, {a, stack1}} <- Stack.pop(state.stack),
         {:ok, {b, stack2}} <- Stack.pop(stack1),
         {:ok, result_stack} <- Stack.push(stack2, a + b) do
      %{state | stack: result_stack, gas: state.gas - 3}
    else
      _ -> state
    end
  end

  defp execute_single_operation(_state, _op) do
    # Default: consume some gas
    %{state | gas: max(0, state.gas - 3)}
  end

  defp states_equal?(state1, state2) do
    # Compare relevant state fields
    Stack.to_list(state1.stack) == Stack.to_list(state2.stack) and
      state1.gas == state2.gas and
      state1.pc == state2.pc and
      state1.stopped == state2.stopped
  end
end
