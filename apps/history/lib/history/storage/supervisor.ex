defmodule History.Storage.Supervisor do
  @moduledoc """
  Supervisor for storage shards.

  Starts and manages CubDB-backed shards for parallel storage access.
  """
  use Supervisor

  @default_shards 16

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    num_shards = Keyword.get(config, :shards, @default_shards)
    data_dir = Keyword.get(config, :data_dir, "./data/history")

    children =
      Enum.map(0..(num_shards - 1), fn id ->
        shard_name = :"history_shard_#{id}"
        Supervisor.child_spec({History.Storage.Shard, {shard_name, data_dir}}, id: shard_name)
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
