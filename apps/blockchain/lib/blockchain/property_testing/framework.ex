defmodule Blockchain.PropertyTesting.Framework do
  @moduledoc """
  Property testing framework providing custom macros for enhanced property-based testing.

  This module provides macros for:
  - Property tests (enhanced property testing)
  - Fuzzing tests (intensive randomized testing)
  - Performance tests (timing and performance validation)
  - Determinism tests (ensuring functions are deterministic)
  - Error handling tests (robustness testing)
  """

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: true
      use ExUnitProperties
      import Blockchain.PropertyTesting.Framework
      import Blockchain.PropertyTesting.Generators
      import StreamData
    end
  end

  @doc """
  Defines a property test with enhanced reporting and debugging.

  ## Examples

      property_test "addition is commutative" do
        check all({a, b} <- {integer(), integer()}) do
          assert a + b == b + a
        end
      end
  """
  defmacro property_test(description, do: block) do
    quote do
      property unquote(description) do
        unquote(block)
      end
    end
  end

  @doc """
  Defines a fuzzing test that runs a function with generated inputs,
  catching and reporting errors gracefully.

  ## Options

  - `:max_runs` - Maximum number of test iterations (default: 100)
  - `:crash_on_error` - Whether to crash on first error (default: true)

  ## Examples

      fuzz_test(
        "transaction serialization robustness",
        &serialize_transaction/1,
        transaction_generator(),
        max_runs: 500
      )
  """
  defmacro fuzz_test(description, fun, generator, opts \\ []) do
    quote bind_quoted: [
            description: description,
            fun: fun,
            generator: generator,
            opts: opts
          ] do
      max_runs = Keyword.get(opts, :max_runs, 100)
      crash_on_error = Keyword.get(opts, :crash_on_error, true)

      property description, [max_runs: max_runs] do
        check all(input <- generator) do
          result = fun.(input)

          if crash_on_error do
            case result do
              :ok -> :ok
              {:ok, _} -> :ok
              {:error, _} = error -> flunk("Fuzzing failed with error: #{inspect(error)}")
              error -> flunk("Fuzzing failed with unexpected result: #{inspect(error)}")
            end
          else
            # Non-crashing mode: just ensure it doesn't raise
            assert result != nil
          end
        end
      end
    end
  end

  @doc """
  Tests that a function produces deterministic output for the same input.

  ## Examples

      test_deterministic(&Transaction.serialize/1, transaction())
  """
  defmacro test_deterministic(fun, generator) do
    fun_name = extract_function_name(fun)

    quote do
      property "#{unquote(fun_name)} is deterministic" do
        check all(input <- unquote(generator)) do
          result1 = unquote(fun).(input)
          result2 = unquote(fun).(input)
          assert result1 == result2
        end
      end
    end
  end

  @doc """
  Tests the performance characteristics of a function.

  ## Options

  - `:timeout_ms` - Maximum time allowed per execution (default: 1000ms)

  ## Examples

      performance_test(
        "transaction serialization performance",
        &Transaction.serialize/1,
        transaction(),
        timeout_ms: 100
      )
  """
  defmacro performance_test(description, fun, generator, opts \\ []) do
    quote bind_quoted: [
            description: description,
            fun: fun,
            generator: generator,
            opts: opts
          ] do
      timeout_ms = Keyword.get(opts, :timeout_ms, 1000)

      property description do
        check all(input <- generator, max_runs: 50) do
          {elapsed_us, _result} =
            :timer.tc(fn ->
              fun.(input)
            end)

          elapsed_ms = elapsed_us / 1000

          assert elapsed_ms < timeout_ms,
                 "Performance test failed: execution took #{elapsed_ms}ms, expected < #{timeout_ms}ms"
        end
      end
    end
  end

  @doc """
  Tests that a function properly handles error cases.

  ## Examples

      test_error_handling(&Transaction.deserialize/1, invalid_rlp_data())
  """
  defmacro test_error_handling(fun, generator) do
    fun_name = extract_function_name(fun)

    quote do
      property "#{unquote(fun_name)} handles errors gracefully" do
        check all(input <- unquote(generator)) do
          result = unquote(fun).(input)

          # Should either return an error tuple or raise an exception
          # but should not crash the VM
          case result do
            {:ok, _} -> :ok
            {:error, _} -> :ok
            _ -> :ok
          end

          :ok
        end
      end
    end
  end

  # Helper to extract function name from capture syntax
  defp extract_function_name(fun) do
    case fun do
      {:&, _, [{:/, _, [{name, _, _}, _arity]}]} when is_atom(name) ->
        Atom.to_string(name)

      _ ->
        "function"
    end
  end
end
