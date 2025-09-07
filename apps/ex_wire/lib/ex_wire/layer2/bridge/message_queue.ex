defmodule ExWire.Layer2.Bridge.MessageQueue do
  @moduledoc """
  Message queue for cross-layer bridge communication.
  Handles ordering, prioritization, and persistence of bridge messages.
  """

  use GenServer
  require Logger

  @type priority :: :high | :normal | :low
  @type message_status :: :pending | :processing | :completed | :failed

  @type queued_message :: %{
          id: String.t(),
          message: map(),
          priority: priority(),
          status: message_status(),
          enqueued_at: DateTime.t(),
          attempts: non_neg_integer()
        }

  @type t :: %__MODULE__{
          pending: list(queued_message()),
          processing: map(),
          completed: list(queued_message()),
          failed: list(queued_message()),
          max_retries: non_neg_integer()
        }

  defstruct pending: [],
            processing: %{},
            completed: [],
            failed: [],
            max_retries: 3

  @doc """
  Creates a new message queue.
  """
  @spec new(keyword()) :: {:ok, t()}
  def new(opts \\ []) do
    queue = %__MODULE__{
      max_retries: opts[:max_retries] || 3
    }

    {:ok, queue}
  end

  @doc """
  Enqueues a message with optional priority.
  """
  @spec enqueue(t(), map(), keyword()) :: {:ok, t()}
  def enqueue(queue, message, opts \\ []) do
    priority = opts[:priority] || :normal

    queued_message = %{
      id: message.id || generate_id(),
      message: message,
      priority: priority,
      status: :pending,
      enqueued_at: DateTime.utc_now(),
      attempts: 0
    }

    new_pending = insert_by_priority(queue.pending, queued_message)

    {:ok, %{queue | pending: new_pending}}
  end

  @doc """
  Dequeues the next message for processing.
  """
  @spec dequeue(t()) :: {:ok, queued_message(), t()} | {:empty, t()}
  def dequeue(queue) do
    case queue.pending do
      [] ->
        {:empty, queue}

      [message | rest] ->
        processing_message = %{message | status: :processing, attempts: message.attempts + 1}

        new_processing = Map.put(queue.processing, message.id, processing_message)

        {:ok, processing_message, %{queue | pending: rest, processing: new_processing}}
    end
  end

  @doc """
  Marks a message as completed.
  """
  @spec complete(t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def complete(queue, message_id) do
    case Map.get(queue.processing, message_id) do
      nil ->
        {:error, :not_found}

      message ->
        completed_message = %{message | status: :completed}

        new_queue = %{
          queue
          | processing: Map.delete(queue.processing, message_id),
            completed: [completed_message | queue.completed]
        }

        {:ok, new_queue}
    end
  end

  @doc """
  Marks a message as failed and potentially retries.
  """
  @spec fail(t(), String.t(), term()) :: {:ok, t()} | {:error, :not_found}
  def fail(queue, message_id, _reason) do
    case Map.get(queue.processing, message_id) do
      nil ->
        {:error, :not_found}

      message ->
        if message.attempts < queue.max_retries do
          # Retry the message
          retry_message = %{message | status: :pending, retry_reason: reason}

          new_queue = %{
            queue
            | processing: Map.delete(queue.processing, message_id),
              pending: insert_by_priority(queue.pending, retry_message)
          }

          Logger.info("Retrying message #{message_id}, attempt #{message.attempts + 1}")

          {:ok, new_queue}
        else
          # Max retries exceeded
          failed_message = %{message | status: :failed, failure_reason: reason}

          new_queue = %{
            queue
            | processing: Map.delete(queue.processing, message_id),
              failed: [failed_message | queue.failed]
          }

          Logger.warning("Message #{message_id} failed after #{message.attempts} attempts")

          {:ok, new_queue}
        end
    end
  end

  @doc """
  Gets pending messages up to a limit.
  """
  @spec get_pending(t(), non_neg_integer()) :: list(map())
  def get_pending(queue, limit \\ 10) do
    queue.pending
    |> Enum.take(limit)
    |> Enum.map(& &1.message)
  end

  @doc """
  Gets the queue size for each status.
  """
  @spec get_stats(t()) :: map()
  def get_stats(queue) do
    %{
      pending: length(queue.pending),
      processing: map_size(queue.processing),
      completed: length(queue.completed),
      failed: length(queue.failed)
    }
  end

  @doc """
  Clears old completed and failed messages.
  """
  @spec cleanup(t(), non_neg_integer()) :: t()
  def cleanup(queue, max_age_seconds \\ 3600) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_seconds, :second)

    %{
      queue
      | completed: filter_recent(queue.completed, cutoff),
        failed: filter_recent(queue.failed, cutoff)
    }
  end

  # Private Functions

  defp generate_id() do
    "msg_queue_" <> Base.encode16(:crypto.strong_rand_bytes(8))
  end

  defp insert_by_priority(list, message) do
    priority_value = priority_to_value(message.priority)

    {before, after_list} =
      Enum.split_while(list, fn m ->
        priority_to_value(m.priority) >= priority_value
      end)

    before ++ [message | after_list]
  end

  defp priority_to_value(:high), do: 3
  defp priority_to_value(:normal), do: 2
  defp priority_to_value(:low), do: 1

  defp filter_recent(messages, cutoff) do
    Enum.filter(messages, fn m ->
      DateTime.compare(m.enqueued_at, cutoff) == :gt
    end)
  end
end
