defmodule ExWire.Config.Migrator do
  @moduledoc """
  Configuration migration tools for upgrading configuration formats
  and applying migrations between versions.
  """

  require Logger

  @migrations_dir "priv/config_migrations"

  defmodule Migration do
    @moduledoc """
    Structure for a configuration migration.
    """
    defstruct [
      :version,
      :description,
      :up,
      :down,
      :applied_at
    ]
  end

  @doc """
  Runs all pending migrations on a configuration.
  """
  def migrate(_config, opts \\ []) do
    target_version = Keyword.get(opts, :to, :latest)
    current_version = get_config_version(config)

    migrations = load_migrations()
    pending = get_pending_migrations(migrations, current_version, target_version)

    case apply_migrations(config, pending) do
      {:ok, new_config} ->
        new_config = set_config_version(new_config, get_latest_version(migrations))
        {:ok, new_config}

      error ->
        error
    end
  end

  @doc """
  Rolls back migrations to a specific version.
  """
  def rollback(_config, to_version) do
    current_version = get_config_version(config)
    migrations = load_migrations()

    to_rollback = get_rollback_migrations(migrations, current_version, to_version)

    case apply_rollbacks(config, to_rollback) do
      {:ok, new_config} ->
        new_config = set_config_version(new_config, to_version)
        {:ok, new_config}

      error ->
        error
    end
  end

  @doc """
  Creates a new migration file.
  """
  def create_migration(name, description \\ "") do
    version = generate_version()
    filename = "#{version}_#{name}.exs"
    filepath = Path.join(@migrations_dir, filename)

    template = migration_template(version, name, description)

    File.mkdir_p!(@migrations_dir)
    File.write!(filepath, template)

    Logger.info("Created migration: #{filepath}")
    {:ok, filepath}
  end

  @doc """
  Lists all available migrations.
  """
  def list_migrations do
    load_migrations()
    |> Enum.map(fn migration ->
      %{
        version: migration.version,
        description: migration.description,
        file: migration_file(migration.version)
      }
    end)
  end

  @doc """
  Checks if a configuration needs migration.
  """
  def needs_migration?(config) do
    current_version = get_config_version(config)
    latest_version = get_latest_version(load_migrations())

    current_version < latest_version
  end

  @doc """
  Validates that migrations can be applied cleanly.
  """
  def validate_migrations(_config, from_version \\ nil, to_version \\ :latest) do
    from = from_version || get_config_version(config)
    migrations = load_migrations()
    pending = get_pending_migrations(migrations, from, to_version)

    # Dry run the migrations
    test_config = deep_copy(config)

    case apply_migrations(test_config, pending) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Private Functions

  defp load_migrations do
    Path.wildcard(Path.join(@migrations_dir, "*.exs"))
    |> Enum.map(&load_migration_file/1)
    |> Enum.filter(&(&1 != nil))
    |> Enum.sort_by(& &1.version)
  end

  defp load_migration_file(filepath) do
    try do
      {migration, _} = Code.eval_file(filepath)

      if is_map(migration) and Map.has_key?(migration, :version) do
        struct(Migration, migration)
      else
        Logger.error("Invalid migration file: #{filepath}")
        nil
      end
    rescue
      error ->
        Logger.error("Failed to load migration #{filepath}: #{inspect(error)}")
        nil
    end
  end

  defp get_pending_migrations(migrations, from_version, :latest) do
    Enum.filter(migrations, fn m -> m.version > from_version end)
  end

  defp get_pending_migrations(migrations, from_version, to_version) do
    Enum.filter(migrations, fn m ->
      m.version > from_version and m.version <= to_version
    end)
  end

  defp get_rollback_migrations(migrations, from_version, to_version) do
    migrations
    |> Enum.filter(fn m ->
      m.version <= from_version and m.version > to_version
    end)
    |> Enum.reverse()
  end

  defp apply_migrations(_config, migrations) do
    Enum.reduce_while(migrations, {:ok, _config}, fn migration, {:ok, current_config} ->
      Logger.info("Applying migration #{migration.version}: #{migration.description}")

      case apply_migration_up(current_config, migration) do
        {:ok, new_config} ->
          {:cont, {:ok, new_config}}

        {:error, _reason} = error ->
          Logger.error("Migration #{migration.version} failed: #{inspect(reason)}")
          {:halt, error}
      end
    end)
  end

  defp apply_rollbacks(_config, migrations) do
    Enum.reduce_while(migrations, {:ok, _config}, fn migration, {:ok, current_config} ->
      Logger.info("Rolling back migration #{migration.version}")

      case apply_migration_down(current_config, migration) do
        {:ok, new_config} ->
          {:cont, {:ok, new_config}}

        error ->
          Logger.error("Rollback of #{migration.version} failed")
          {:halt, error}
      end
    end)
  end

  defp apply_migration_up(_config, migration) do
    if is_function(migration.up, 1) do
      try do
        migration.up.(config)
      rescue
        error -> {:error, error}
      end
    else
      {:ok, _config}
    end
  end

  defp apply_migration_down(_config, migration) do
    if is_function(migration.down, 1) do
      try do
        migration.down.(config)
      rescue
        error -> {:error, error}
      end
    else
      {:ok, _config}
    end
  end

  defp get_config_version(_config) do
    Map.get(config, :__version__, "0.0.0")
  end

  defp set_config_version(_config, version) do
    Map.put(config, :__version__, version)
  end

  defp get_latest_version([]), do: "0.0.0"

  defp get_latest_version(migrations) do
    migrations
    |> List.last()
    |> Map.get(:version)
  end

  defp generate_version do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    :io_lib.format(
      "~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B",
      [year, month, day, hour, minute, second]
    )
    |> IO.iodata_to_binary()
  end

  defp migration_file(version) do
    Path.join(@migrations_dir, "#{version}_*.exs")
    |> Path.wildcard()
    |> List.first()
  end

  defp migration_template(version, name, description) do
    """
    %{
      version: "#{version}",
      description: "#{description}",
      
      up: fn config ->
        # Add your migration logic here
        # Example:
        # config
        # |> Map.put(:new_field, "default_value")
        # |> Map.update(:existing_field, nil, fn old -> transform(old) end)
        
        {:ok, _config}
      end,
      
      down: fn config ->
        # Add your rollback logic here
        # This should reverse the changes made in 'up'
        
        {:ok, _config}
      end
    }
    """
  end

  defp deep_copy(term) do
    :erlang.binary_to_term(:erlang.term_to_binary(term))
  end

  @doc """
  Common migration transformations.
  """
  defmodule Transformations do
    @moduledoc """
    Reusable transformation functions for migrations.
    """

    @doc "Renames a configuration key"
    def rename_key(_config, old_key, new_key) do
      if Map.has_key?(config, old_key) do
        config
        |> Map.put(new_key, Map.get(config, old_key))
        |> Map.delete(old_key)
      else
        config
      end
    end

    @doc "Moves a value to a nested location"
    def nest_value(_config, key, path) when is_list(path) do
      if Map.has_key?(config, key) do
        value = Map.get(config, key)

        config
        |> Map.delete(key)
        |> put_in(path, value)
      else
        config
      end
    end

    @doc "Flattens a nested value"
    def flatten_value(_config, path, key) when is_list(path) do
      case get_in(config, path) do
        nil ->
          config

        value ->
          config
          |> Map.put(key, value)
          |> update_in(List.take(path, length(path) - 1), &Map.delete(&1, List.last(path)))
      end
    end

    @doc "Transforms values matching a pattern"
    def transform_values(_config, pattern, transformer) when is_function(transformer, 1) do
      deep_transform(config, fn key, value ->
        if matches_pattern?(key, pattern) do
          transformer.(value)
        else
          value
        end
      end)
    end

    defp deep_transform(_config, transformer) when is_map(config) do
      Map.new(_config, fn {key, value} ->
        new_value =
          if is_map(value) do
            deep_transform(value, transformer)
          else
            transformer.(key, value)
          end

        {key, new_value}
      end)
    end

    defp matches_pattern?(key, pattern) when is_atom(pattern) do
      key == pattern
    end

    defp matches_pattern?(key, pattern) when is_function(pattern, 1) do
      pattern.(key)
    end
  end
end
