defmodule Common.Production.ValidationMiddleware do
  @moduledoc """
  Middleware that validates and sanitizes JSON-RPC requests before processing.

  Integrates with:
  - Input validation for security
  - Rate limiting for DoS protection
  - Circuit breaker for fault tolerance
  - Telemetry for monitoring
  """

  alias Common.Production.InputValidator
  # Note: RateLimiter and CircuitBreaker are loaded dynamically if available
  require Logger

  @doc """
  Wraps a handler function with validation, rate limiting, and circuit breaking.
  """
  @spec wrap_handler(function(), keyword()) :: function()
  def wrap_handler(handler, opts \\ []) do
    fn method, params ->
      start_time = System.monotonic_time()

      # Build request for validation
      request = %{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params,
        "id" => 1
      }

      # Validate input
      case validate_and_sanitize(request, opts) do
        {:ok, validated_request} ->
          # Check rate limit
          case check_rate_limit(method, opts) do
            :ok ->
              # Execute with circuit breaker
              execute_with_protection(
                handler,
                validated_request["method"],
                validated_request["params"],
                start_time,
                opts
              )

            {:error, :rate_limited} ->
              emit_telemetry(:rate_limited, method, start_time)
              {:error, %{code: -32000, message: "Rate limit exceeded"}}
          end

        {:error, reason} ->
          emit_telemetry(:validation_failed, method, start_time)
          Logger.warning("Request validation failed", method: method, reason: reason)
          {:error, %{code: -32602, message: "Invalid params: #{inspect(reason)}"}}
      end
    end
  end

  @doc """
  Validates and processes a batch request.
  """
  @spec process_batch(list(), function(), keyword()) :: list()
  def process_batch(requests, handler, opts \\ []) do
    case InputValidator.validate_batch(requests) do
      {:ok, validated_requests} ->
        # Process each request with rate limiting
        Enum.map(validated_requests, fn req ->
          wrapped = wrap_handler(handler, opts)

          case wrapped.(req["method"], req["params"]) do
            {:error, error} ->
              %{
                "jsonrpc" => "2.0",
                "id" => req["id"],
                "error" => error
              }

            result ->
              %{
                "jsonrpc" => "2.0",
                "id" => req["id"],
                "result" => result
              }
          end
        end)

      {:error, reason} ->
        [
          %{
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => %{
              code: -32600,
              message: "Invalid batch request: #{inspect(reason)}"
            }
          }
        ]
    end
  end

  # Private functions

  defp validate_and_sanitize(request, _opts) do
    InputValidator.validate_request(request)
  end

  defp check_rate_limit(method, opts) do
    if Keyword.get(opts, :rate_limiting, true) do
      # Get client identifier (could be IP, API key, etc.)
      client_id = get_client_id(opts)

      # Check rate limit for this client and method
      if Code.ensure_loaded?(JSONRPC2.RateLimiter) do
        apply(JSONRPC2.RateLimiter, :check_rate, [client_id, method_category(method)])
      else
        :ok
      end
    else
      :ok
    end
  end

  defp execute_with_protection(handler, method, params, start_time, opts) do
    circuit_breaker = Keyword.get(opts, :circuit_breaker, :jsonrpc)

    try do
      result =
        if circuit_breaker && Code.ensure_loaded?(Common.CircuitBreaker) do
          apply(Common.CircuitBreaker, :call, [
            circuit_breaker,
            fn ->
              handler.(method, params)
            end
          ])
        else
          handler.(method, params)
        end

      emit_telemetry(:success, method, start_time)

      case result do
        {:ok, response} -> response
        {:error, _} = error -> error
        response -> response
      end
    rescue
      exception ->
        emit_telemetry(:error, method, start_time)

        Logger.error("Handler exception",
          method: method,
          error: Exception.message(exception),
          stacktrace: __STACKTRACE__
        )

        {:error,
         %{
           code: -32603,
           message: "Internal error"
         }}
    end
  end

  defp get_client_id(opts) do
    # In a real implementation, this would extract client ID from:
    # - IP address
    # - API key
    # - JWT token
    # - Session ID
    Keyword.get(opts, :client_id, "default")
  end

  defp method_category(method) do
    cond do
      String.starts_with?(method, "eth_send") -> :write
      String.starts_with?(method, "eth_get") -> :read
      String.starts_with?(method, "eth_") -> :eth
      String.starts_with?(method, "net_") -> :net
      String.starts_with?(method, "web3_") -> :web3
      true -> :other
    end
  end

  defp emit_telemetry(event, method, start_time) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:jsonrpc, :request, event],
      %{duration: duration},
      %{method: method}
    )
  end
end
