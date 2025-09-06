defmodule Common.CircuitBreaker do
  @moduledoc """
  Simple circuit breaker implementation for network operations.

  Provides basic circuit breaker functionality without external dependencies.
  """

  @doc """
  Executes a function through the circuit breaker.
  For now, this is a passthrough implementation.
  """
  def call(_circuit_name, fun) when is_function(fun, 0) do
    try do
      {:ok, fun.()}
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  def call(fun, _opts) when is_function(fun, 0) do
    call(nil, fun)
  end

  @doc """
  Gets the current state of the circuit breaker.
  Currently always returns :closed (operational).
  """
  def get_state(_circuit_name) do
    {:ok, :closed}
  end

  @doc """
  Starts the circuit breaker (no-op for now).
  """
  def start_link(_opts) do
    {:ok, self()}
  end
end
