defmodule Mana.Migration.BackupManager do
  @moduledoc """
  Manages backups for safe V1 to V2 migrations.

  This module provides:
  - State backup creation and restoration
  - Backup validation and integrity checking
  - Backup cleanup and retention management
  - Compressed storage for large states
  - Multiple backup storage backends
  """

  require Logger

  @backup_version "1.0.0"
  @default_retention_days 30
  # 1MB
  @compression_threshold 1024 * 1024

  @type backup_ref :: reference()
  @type backup_metadata :: map()

  @doc """
  Creates a backup of module state.

  ## Parameters
  - module_type: The type of module being backed up
  - state: The state to backup
  - metadata: Additional backup metadata

  ## Returns
  - {:ok, backup_ref} on success
  - {:error, _reason} on failure
  """
  @spec create_backup(atom(), map(), backup_metadata()) :: {:ok, backup_ref()} | {:error, term()}
  def create_backup(module_type, _state, metadata \\ %{}) do
    backup_ref = make_ref()
    timestamp = System.system_time(:second)

    Logger.info("Creating backup", %{
      module_type: module_type,
      backup_ref: backup_ref,
      state_size: estimate_state_size(state)
    })

    start_time = :os.system_time(:microsecond)

    with {:ok, backup_data} <-
           safe_prepare_backup_data(module_type, state, metadata, timestamp, backup_ref),
         :ok <- store_backup(backup_ref, backup_data) do
      duration_ms = (:os.system_time(:microsecond) - start_time) / 1000

      Logger.info("Backup created successfully", %{
        module_type: module_type,
        backup_ref: backup_ref,
        duration_ms: duration_ms,
        compressed: backup_data.compression
      })

      emit_telemetry(:backup_created, %{
        module_type: module_type,
        backup_ref: backup_ref,
        duration_ms: duration_ms,
        compressed: backup_data.compression
      })

      {:ok, backup_ref}
    else
      {:error, _reason} = error ->
        Logger.error("Backup creation failed", %{
          module_type: module_type,
          backup_ref: backup_ref,
          reason: reason
        })

        error
    end
  end

  @doc """
  Restores state from a backup.

  ## Parameters
  - backup_ref: Reference to the backup to restore

  ## Returns
  - {:ok, _state} on successful restoration
  - {:error, _reason} on failure
  """
  @spec restore_backup(backup_ref()) :: {:ok, map()} | {:error, term()}
  def restore_backup(backup_ref) do
    Logger.info("Restoring backup", %{backup_ref: backup_ref})

    start_time = :os.system_time(:microsecond)

    with {:ok, backup_data} <- load_backup(backup_ref),
         :ok <- validate_backup_integrity(backup_data) do
      state = backup_data.state
      duration_ms = (:os.system_time(:microsecond) - start_time) / 1000

      Logger.info("Backup restored successfully", %{
        backup_ref: backup_ref,
        module_type: backup_data.module_type,
        duration_ms: duration_ms,
        state_size: estimate_state_size(state)
      })

      emit_telemetry(:backup_restored, %{
        backup_ref: backup_ref,
        module_type: backup_data.module_type,
        duration_ms: duration_ms
      })

      {:ok, _state}
    else
      {:error, _reason} = error ->
        Logger.error("Backup restoration failed", %{
          backup_ref: backup_ref,
          reason: reason
        })

        error
    end
  end

  @doc """
  Lists all available backups.

  ## Returns
  List of backup information maps.
  """
  @spec list_backups() :: [map()]
  def list_backups do
    safe_list_backups()
  end

  defp safe_list_backups do
    get_all_backup_refs()
    |> Enum.map(fn backup_ref ->
      case get_backup_metadata(backup_ref) do
        {:ok, metadata} ->
          Map.merge(metadata, %{backup_ref: backup_ref})

        {:error, _reason} ->
          %{
            backup_ref: backup_ref,
            status: :corrupted,
            created_at: nil,
            module_type: :unknown
          }
      end
    end)
    |> Enum.sort_by(fn backup -> Map.get(backup, :created_at, 0) end, :desc)
  rescue
    _error ->
      []
  end

  @doc """
  Gets detailed information about a specific backup.

  ## Parameters
  - backup_ref: Reference to the backup

  ## Returns
  - {:ok, backup_info} on success
  - {:error, _reason} if backup not found or corrupted
  """
  @spec get_backup_info(backup_ref()) :: {:ok, map()} | {:error, term()}
  def get_backup_info(backup_ref) do
    case load_backup(backup_ref) do
      {:ok, backup_data} ->
        info = %{
          backup_ref: backup_ref,
          version: backup_data.version,
          module_type: backup_data.module_type,
          metadata: backup_data.metadata,
          state_size: estimate_state_size(backup_data.state),
          compressed: backup_data.compression,
          storage_size: get_storage_size(backup_ref),
          integrity_status: validate_backup_integrity(backup_data)
        }

        {:ok, info}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Deletes a backup.

  ## Parameters
  - backup_ref: Reference to the backup to delete

  ## Returns
  - :ok on successful deletion
  - {:error, _reason} on failure
  """
  @spec delete_backup(backup_ref()) :: :ok | {:error, term()}
  def delete_backup(backup_ref) do
    Logger.info("Deleting backup", %{backup_ref: backup_ref})

    case remove_backup_storage(backup_ref) do
      :ok ->
        Logger.info("Backup deleted successfully", %{backup_ref: backup_ref})

        emit_telemetry(:backup_deleted, %{backup_ref: backup_ref})

        :ok

      {:error, _reason} = error ->
        Logger.error("Backup deletion failed", %{
          backup_ref: backup_ref,
          reason: reason
        })

        error
    end
  end

  @doc """
  Cleans up old backups based on retention policy.

  ## Parameters
  - retention_days: Number of days to retain backups (default: 30)

  ## Returns
  - {:ok, deleted_count} on success
  - {:error, _reason} on failure
  """
  @spec cleanup_old_backups(non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_old_backups(retention_days \\ @default_retention_days) do
    Logger.info("Starting backup cleanup", %{retention_days: retention_days})

    cutoff_time = System.system_time(:second) - retention_days * 24 * 60 * 60

    with {:ok, deleted_count} <- safe_cleanup_old_backups(cutoff_time) do
      Logger.info("Cleanup completed", %{
        retention_days: retention_days,
        deleted_count: deleted_count
      })

      emit_telemetry(:cleanup_completed, %{
        retention_days: retention_days,
        deleted_count: deleted_count
      })

      {:ok, deleted_count}
    else
      {:error, _reason} = error ->
        Logger.error("Cleanup failed", %{
          reason: reason
        })

        error
    end
  end

  defp safe_cleanup_old_backups(cutoff_time) do
    old_backups =
      list_backups()
      |> Enum.filter(fn backup ->
        created_at = Map.get(backup, :created_at, 0)
        created_at < cutoff_time
      end)

    deleted_count =
      Enum.reduce(old_backups, 0, fn backup, acc ->
        backup_ref = Map.get(backup, :backup_ref)

        case delete_backup(backup_ref) do
          :ok ->
            acc + 1

          {:error, _reason} ->
            Logger.warning("Failed to delete old backup", %{
              backup_ref: backup_ref,
              reason: reason
            })

            acc
        end
      end)

    {:ok, deleted_count}
  rescue
    exception ->
      {:error, {:exception, exception}}
  end

  @doc """
  Validates the integrity of all stored backups.

  ## Returns
  - {:ok, validation_report} with details of validation results
  - {:error, _reason} on failure
  """
  @spec validate_all_backups() :: {:ok, map()} | {:error, term()}
  def validate_all_backups do
    Logger.info("Starting backup validation")

    start_time = :os.system_time(:microsecond)

    with {:ok, validation_report} <- safe_validate_all_backups(start_time) do
      Logger.info("Backup validation completed", %{
        total_backups: validation_report.total_backups,
        valid_backups: validation_report.valid_backups,
        invalid_backups: validation_report.invalid_backups,
        duration_ms: validation_report.validation_duration_ms
      })

      emit_telemetry(:backup_validation_completed, %{
        total_backups: validation_report.total_backups,
        valid_backups: validation_report.valid_backups,
        invalid_backups: validation_report.invalid_backups,
        duration_ms: validation_report.validation_duration_ms
      })

      {:ok, validation_report}
    else
      {:error, _reason} = error ->
        Logger.error("Backup validation failed", %{
          reason: reason
        })

        error
    end
  end

  defp safe_validate_all_backups(start_time) do
    backup_refs = get_all_backup_refs()

    validation_results =
      Enum.map(backup_refs, fn backup_ref ->
        case load_backup(backup_ref) do
          {:ok, backup_data} ->
            integrity_result = validate_backup_integrity(backup_data)

            %{
              backup_ref: backup_ref,
              module_type: backup_data.module_type,
              created_at: get_in(backup_data, [:metadata, :created_at]),
              integrity_status: integrity_result,
              valid: integrity_result == :ok
            }

          {:error, _reason} ->
            %{
              backup_ref: backup_ref,
              module_type: :unknown,
              created_at: nil,
              integrity_status: {:error, _reason},
              valid: false
            }
        end
      end)

    total_backups = length(validation_results)
    valid_backups = Enum.count(validation_results, & &1.valid)
    invalid_backups = total_backups - valid_backups

    duration_ms = (:os.system_time(:microsecond) - start_time) / 1000

    validation_report = %{
      total_backups: total_backups,
      valid_backups: valid_backups,
      invalid_backups: invalid_backups,
      validation_duration_ms: duration_ms,
      details: validation_results,
      validated_at: System.system_time(:second)
    }

    {:ok, validation_report}
  rescue
    exception ->
      {:error, {:exception, exception}}
  end

  # Private Implementation

  defp estimate_state_size(_state) when is_map(state) do
    :erlang.external_size(state)
  end

  defp estimate_state_size(_state), do: 0

  defp calculate_checksum(_state) do
    state
    |> :erlang.term_to_binary()
    |> :crypto.hash(:sha256)
    |> Base.encode16(case: :lower)
  end

  defp should_compress?(state) do
    estimate_state_size(state) > @compression_threshold
  end

  defp store_backup(backup_ref, backup_data) do
    # Use ETS as simple storage backend (in production, would use persistent storage)
    table_name = ensure_backup_table()

    # Optionally compress the data
    final_data =
      if backup_data.compression do
        compressed_state = :zlib.compress(:erlang.term_to_binary(backup_data.state))
        %{backup_data | state: compressed_state}
      else
        backup_data
      end

    safe_ets_insert(table_name, backup_ref, final_data)
  end

  defp load_backup(backup_ref) do
    table_name = ensure_backup_table()

    safe_load_backup_internal(table_name, backup_ref)
  end

  defp safe_load_backup_internal(table_name, backup_ref) do
    case :ets.lookup(table_name, backup_ref) do
      [{^backup_ref, backup_data}] ->
        # Decompress if necessary
        final_data =
          if backup_data.compression do
            decompressed_state =
              backup_data.state
              |> :zlib.uncompress()
              |> :erlang.binary_to_term()

            %{backup_data | state: decompressed_state}
          else
            backup_data
          end

        {:ok, final_data}

      [] ->
        {:error, :backup_not_found}
    end
  rescue
    error ->
      {:error, {:load_error, error}}
  end

  defp validate_backup_integrity(backup_data) do
    safe_validate_backup_integrity_internal(backup_data)
  end

  defp safe_validate_backup_integrity_internal(backup_data) do
    # Check version compatibility
    case backup_data.version do
      @backup_version ->
        # Validate checksum if present
        case get_in(backup_data, [:metadata, :state_checksum]) do
          nil ->
            # No checksum to validate
            :ok

          expected_checksum ->
            actual_checksum = calculate_checksum(backup_data._state)

            if actual_checksum == expected_checksum do
              :ok
            else
              {:error, :checksum_mismatch}
            end
        end

      other_version ->
        {:error, {:unsupported_version, other_version}}
    end
  rescue
    error ->
      {:error, {:validation_error, error}}
  end

  defp get_backup_metadata(backup_ref) do
    case load_backup(backup_ref) do
      {:ok, backup_data} ->
        {:ok, backup_data.metadata}

      {:error, _reason} ->
        {:error, _reason}
    end
  end

  defp get_all_backup_refs do
    table_name = ensure_backup_table()

    :ets.select(table_name, [{{:"$1", :"$2"}, [], [:"$1"]}])
  end

  defp get_storage_size(backup_ref) do
    case load_backup(backup_ref) do
      {:ok, backup_data} ->
        :erlang.external_size(backup_data)

      {:error, _reason} ->
        0
    end
  end

  defp remove_backup_storage(backup_ref) do
    table_name = ensure_backup_table()

    safe_ets_delete(table_name, backup_ref)
  end

  defp safe_ets_delete(table_name, backup_ref) do
    :ets.delete(table_name, backup_ref)
    :ok
  rescue
    error ->
      {:error, {:deletion_error, error}}
  end

  defp ensure_backup_table do
    table_name = :mana_migration_backups

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set])

      _ ->
        table_name
    end
  end

  # Helper functions for functional error handling

  defp safe_prepare_backup_data(module_type, _state, metadata, timestamp, backup_ref) do
    backup_data = %{
      version: @backup_version,
      module_type: module_type,
      state: state,
      metadata:
        Map.merge(metadata, %{
          created_at: timestamp,
          backup_ref: backup_ref,
          state_checksum: calculate_checksum(_state)
        }),
      compression: should_compress?(state)
    }

    {:ok, backup_data}
  rescue
    exception ->
      {:error, {:preparation_error, exception}}
  end

  defp safe_ets_insert(table_name, backup_ref, final_data) do
    :ets.insert(table_name, {backup_ref, final_data})
    :ok
  rescue
    error ->
      {:error, {:storage_error, error}}
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:mana, :backup_manager, event],
      %{count: 1, timestamp: :os.system_time(:millisecond)},
      metadata
    )
  end
end
