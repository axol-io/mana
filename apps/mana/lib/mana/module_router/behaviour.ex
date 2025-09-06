defmodule Mana.ModuleRouter.Behaviour do
  @moduledoc """
  Behaviour for module routing implementations.

  This behaviour defines the interface that module routers must implement
  to provide version routing capabilities between V1 and V2 modules.
  """

  @doc """
  Routes a request to the appropriate module version.

  ## Parameters
  - module_type: The type of module (e.g., :transaction_pool, :sync_service)
  - operation: The operation to perform (e.g., :add_transaction, :get_sync_status)
  - args: Arguments for the operation
  - opts: Additional options including caller info, timeout, etc.

  ## Returns
  - {:ok, result} on successful operation
  - {:error, reason} on failure
  """
  @callback route_request(
              module_type :: atom(),
              operation :: atom(),
              args :: list(),
              opts :: keyword()
            ) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Gets the current routing configuration for all modules.

  ## Returns
  A map containing routing configuration for each module type.
  """
  @callback get_routing_config() :: map()

  @doc """
  Gets comprehensive routing statistics.

  ## Returns
  A map containing routing statistics including request counts,
  success rates, latencies, and circuit breaker states.
  """
  @callback get_routing_stats() :: map()

  @doc """
  Forces a specific module to use a particular version.

  This is primarily used for testing and debugging purposes.

  ## Parameters
  - module_type: The module to force
  - version: Either :v1 or :v2

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  @callback force_version(module_type :: atom(), version :: :v1 | :v2) ::
              :ok | {:error, term()}

  @doc """
  Clears version forcing for a module.

  Returns the module to normal routing behavior.

  ## Parameters
  - module_type: The module to clear forcing for

  ## Returns
  - :ok always
  """
  @callback clear_forced_version(module_type :: atom()) :: :ok

  @doc """
  Manually triggers fallback to V1 for a specific module.

  This opens the circuit breaker and forces all traffic to V1
  until the circuit breaker resets.

  ## Parameters
  - module_type: The module to trigger fallback for
  - reason: The reason for the fallback

  ## Returns
  - :ok always
  """
  @callback trigger_fallback(module_type :: atom(), reason :: term()) :: :ok
end
