defmodule MerklePatriciaTree.DB.Migration.ETSToAntidote do
  @moduledoc """
  Migration tool for transferring data from ETS to AntidoteDB.

  This module provides functionality to migrate existing ETS-based storage
  to the distributed AntidoteDB storage system, supporting both full and
  incremental migrations.
  """

  alias MerklePatriciaTree.DB.{ETS, Antidote}
  require Logger

  @batch_size 1000
  @checkpoint_interval 10_000

  @type migration_opts :: [
          batch_size: pos_integer(),
          checkpoint_interval: pos_integer(),
          checkpoint_file: String.t(),
          dry_run: boolean(),
          verbose: boolean()
        ]

  @doc """
  Migrates data from ETS to AntidoteDB.

  Options:
    - batch_size: Number of records to process in each batch (default: 1000)
    - checkpoint_interval: Save progress every N records (default: 10000)
    - checkpoint_file: Path to checkpoint file for resuming (default: ".migration_checkpoint")
    - dry_run: If true, only simulate the migration (default: false)
    - verbose: Enable detailed logging (default: false)
  """
  @spec migrate(ETS.db_ref(), Antidote.db_ref(), migration_opts()) ::
          {:ok, map()} | {:error, term()}
  def migrate(ets_ref, antidote_ref, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    checkpoint_interval = Keyword.get(opts, :checkpoint_interval, @checkpoint_interval)
    checkpoint_file = Keyword.get(opts, :checkpoint_file, ".migration_checkpoint")
    dry_run = Keyword.get(opts, :dry_run, false)
    verbose = Keyword.get(opts, :verbose, false)

    Logger.info("Starting ETS to AntidoteDB migration...")
    Logger.info("Options: batch_size=#{batch_size}, dry_run=#{dry_run}")

    # Load checkpoint if exists
    start_position = load_checkpoint(checkpoint_file)

    # Get all keys from ETS
    case get_all_keys(ets_ref) do
      {:ok, keys} ->
        total_keys = length(keys)
        Logger.info("Found #{total_keys} keys to migrate")

        # Skip already processed keys if resuming
        remaining_keys =
          if start_position > 0 do
            Enum.drop(keys, start_position)
          else
            keys
          end

        # Process in batches
        result =
          process_batches(
            remaining_keys,
            ets_ref,
            antidote_ref,
            batch_size,
            checkpoint_interval,
            checkpoint_file,
            start_position,
            total_keys,
            dry_run,
            verbose
          )

        # Clean up checkpoint file on success
        if elem(result, 0) == :ok do
          File.rm(checkpoint_file)
        end

        result

      {:error, reason} ->
        Logger.error("Failed to get keys from ETS: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Verifies that the migration was successful by comparing data.
  """
  @spec verify_migration(ETS.db_ref(), Antidote.db_ref(), migration_opts()) ::
          {:ok, map()} | {:error, term()}
  def verify_migration(ets_ref, antidote_ref, opts \\ []) do
    sample_size = Keyword.get(opts, :sample_size, 100)
    verbose = Keyword.get(opts, :verbose, false)

    Logger.info("Verifying migration with sample size: #{sample_size}")

    case get_all_keys(ets_ref) do
      {:ok, keys} ->
        # Sample random keys for verification
        sampled_keys = Enum.take_random(keys, min(sample_size, length(keys)))

        mismatches =
          Enum.reduce(sampled_keys, [], fn key, acc ->
            ets_value = ETS.get(ets_ref, key)
            antidote_value = Antidote.get(antidote_ref, key)

            case {ets_value, antidote_value} do
              {:not_found, :not_found} ->
                acc

              {val, val} ->
                acc

              {ets_val, ant_val} ->
                if verbose do
                  Logger.warning(
                    "Mismatch for key #{inspect(key)}: " <>
                      "ETS=#{inspect(ets_val)}, AntidoteDB=#{inspect(ant_val)}"
                  )
                end

                [{key, ets_val, ant_val} | acc]
            end
          end)

        if mismatches == [] do
          {:ok,
           %{
             verified: true,
             sample_size: length(sampled_keys),
             mismatches: 0
           }}
        else
          {:error,
           %{
             verified: false,
             sample_size: length(sampled_keys),
             mismatches: length(mismatches),
             examples: Enum.take(mismatches, 5)
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp get_all_keys(ets_ref) do
    try do
      # Get the ETS table from the ref
      table =
        case ets_ref do
          {MerklePatriciaTree.DB.ETS, table_name} -> table_name
          table_name when is_atom(table_name) -> table_name
          _ -> throw({:error, :invalid_ets_ref})
        end

      keys = :ets.foldl(fn {key, _value}, acc -> [key | acc] end, [], table)
      {:ok, keys}
    catch
      {:error, reason} -> {:error, reason}
      _type, error -> {:error, error}
    end
  end

  defp process_batches(
         keys,
         ets_ref,
         antidote_ref,
         batch_size,
         checkpoint_interval,
         checkpoint_file,
         position,
         total,
         dry_run,
         verbose
       ) do
    chunks = Enum.chunk_every(keys, batch_size)

    stats = %{
      processed: position,
      succeeded: 0,
      failed: 0,
      skipped: 0,
      start_time: System.monotonic_time(:millisecond)
    }

    final_stats =
      Enum.reduce_while(chunks, stats, fn batch, acc ->
        batch_result = process_batch(batch, ets_ref, antidote_ref, dry_run, verbose)

        # Since process_batch always returns {:ok, stats}, we can simplify this
        {:ok, batch_stats} = batch_result

        new_stats = %{
          acc
          | processed: acc.processed + batch_stats.count,
            succeeded: acc.succeeded + batch_stats.succeeded,
            failed: acc.failed + batch_stats.failed,
            skipped: acc.skipped + batch_stats.skipped
        }

        # Progress reporting
        if rem(new_stats.processed, 1000) == 0 do
          progress = Float.round(new_stats.processed / total * 100, 1)
          Logger.info("Progress: #{new_stats.processed}/#{total} (#{progress}%)")
        end

        # Checkpoint saving
        if rem(new_stats.processed, checkpoint_interval) == 0 do
          save_checkpoint(checkpoint_file, new_stats.processed)
        end

        {:cont, new_stats}
      end)

    case final_stats do
      {:error, reason, stats} ->
        {:error, %{reason: reason, stats: finalize_stats(stats, total)}}

      stats ->
        {:ok, finalize_stats(stats, total)}
    end
  end

  defp process_batch(keys, ets_ref, antidote_ref, dry_run, verbose) do
    results =
      Enum.map(keys, fn key ->
        case ETS.get(ets_ref, key) do
          :not_found ->
            if verbose, do: Logger.debug("Key not found in ETS: #{inspect(key)}")
            {:skipped, key}

          value ->
            if dry_run do
              if verbose, do: Logger.debug("Would migrate: #{inspect(key)}")
              {:ok, key}
            else
              # Use put! which always returns :ok or raises
              try do
                Antidote.put!(antidote_ref, key, value)
                if verbose, do: Logger.debug("Migrated: #{inspect(key)}")
                {:ok, key}
              rescue
                error ->
                  Logger.error("Failed to migrate key #{inspect(key)}: #{inspect(error)}")
                  {:error, key}
              end
            end
        end
      end)

    succeeded = Enum.count(results, fn r -> elem(r, 0) == :ok end)
    failed = Enum.count(results, fn r -> elem(r, 0) == :error end)
    skipped = Enum.count(results, fn r -> elem(r, 0) == :skipped end)

    {:ok,
     %{
       count: length(keys),
       succeeded: succeeded,
       failed: failed,
       skipped: skipped
     }}
  end

  defp save_checkpoint(file, position) do
    File.write!(file, Integer.to_string(position))
    Logger.debug("Checkpoint saved at position: #{position}")
  end

  defp load_checkpoint(file) do
    case File.read(file) do
      {:ok, content} ->
        position = String.to_integer(String.trim(content))
        Logger.info("Resuming from checkpoint: #{position}")
        position

      {:error, :enoent} ->
        0

      {:error, reason} ->
        Logger.warning("Failed to load checkpoint: #{inspect(reason)}")
        0
    end
  end

  defp finalize_stats(stats, total) do
    elapsed = System.monotonic_time(:millisecond) - stats.start_time
    rate = if elapsed > 0, do: stats.processed / (elapsed / 1000), else: 0

    Map.merge(stats, %{
      total: total,
      elapsed_ms: elapsed,
      rate_per_sec: Float.round(rate, 2),
      completion_percent: Float.round(stats.processed / total * 100, 2)
    })
    |> Map.delete(:start_time)
  end
end
