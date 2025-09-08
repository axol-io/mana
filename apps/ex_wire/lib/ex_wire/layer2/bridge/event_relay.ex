defmodule ExWire.Layer2.Bridge.EventRelay do
  @moduledoc """
  Event relay for monitoring and propagating events between L1 and L2.
  """

  use GenServer
  require Logger

  @doc """
  Starts monitoring events for a specific contract on a layer.
  """
  def start_monitoring(callback_pid, contract_address, layer) do
    Logger.info("Starting event monitoring for #{Base.encode16(contract_address)} on #{layer}")

    # In production, this would connect to actual event sources
    # For now, we'll simulate event monitoring
    {:ok, _pid} =
      GenServer.start_link(__MODULE__, %{
        callback_pid: callback_pid,
        contract: contract_address,
        layer: layer
      })
  end

  # GenServer callbacks

  def init(_state) do
    # Schedule periodic event checks
    Process.send_after(self(), :check_events, 1000)
    {:ok, _state}
  end

  def handle_info(:check_events, _state) do
    # Simulate event checking
    # In production, this would query blockchain events

    # Occasionally send simulated events to callback
    if :rand.uniform(10) > 8 do
      send(state.callback_pid, {:"#{state.layer}_event", generate_mock_event(state)})
    end

    Process.send_after(self(), :check_events, 1000)
    {:noreply, state}
  end

  defp generate_mock_event(_state) do
    %{
      layer: state.layer,
      contract: state.contract,
      type: Enum.random([:deposit, :withdrawal, :message]),
      data: :crypto.strong_rand_bytes(32),
      timestamp: DateTime.utc_now()
    }
  end
end
