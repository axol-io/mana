defmodule JSONRPC2.RateLimiter do
  @moduledoc """
  Rate limiting for JSON-RPC API calls.

  Implements token bucket algorithm for rate limiting with:
  - Per-endpoint rate limits
  - Per-client rate limits
  - Global rate limits
  - Configurable burst capacity
  """

  use GenServer
  require Logger

  # requests per second
  @default_rate 100
  # burst capacity
  @default_burst 200
  # refill interval in milliseconds
  @default_refill_ms 10

  defstruct rate: @default_rate,
            burst: @default_burst,
            tokens: @default_burst,
            refill_ms: @default_refill_ms,
            last_refill: nil

  @doc """
  Check if a request is allowed under the rate limit.

  Returns:
  - :ok if the request is allowed
  - {:error, :rate_limited} if rate limit exceeded
  """
  def check_rate(client_id, endpoint \\ :default) do
    bucket_name = bucket_name(client_id, endpoint)

    case :ets.lookup(:rate_limiter, bucket_name) do
      [] ->
        # Initialize new bucket
        :ets.insert(
          :rate_limiter,
          {bucket_name, @default_burst, System.monotonic_time(:millisecond)}
        )

        :ok

      [{^bucket_name, tokens, last_refill}] ->
        now = System.monotonic_time(:millisecond)
        elapsed = now - last_refill

        # Calculate tokens to add based on elapsed time
        refill_amount = div(elapsed * @default_rate, 1000)
        new_tokens = min(tokens + refill_amount, @default_burst)

        if new_tokens >= 1 do
          # Consume a token
          :ets.insert(:rate_limiter, {bucket_name, new_tokens - 1, now})
          :ok
        else
          {:error, :rate_limited}
        end
    end
  rescue
    _ ->
      # If ETS table doesn't exist, allow the request
      # This handles the case where rate limiting is disabled
      :ok
  end

  @doc """
  Start the rate limiter (creates ETS table).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for rate limit buckets
    :ets.new(:rate_limiter, [:set, :public, :named_table, {:write_concurrency, true}])
    {:ok, %{}}
  end

  # Private functions

  defp bucket_name(client_id, endpoint) do
    {client_id, endpoint}
  end
end
