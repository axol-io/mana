defmodule Blockchain.Compliance.BaseCompliance do
  @moduledoc """
  Base behaviour and common functionality for compliance modules.
  Helps break down monolithic compliance files into focused, composable modules.
  """

  @doc """
  Defines the callback for processing a compliance event.
  """
  @callback process_event(event :: map()) :: {:ok, result :: map()} | {:error, reason :: term()}

  @doc """
  Defines the callback for validating compliance requirements.
  """
  @callback validate(data :: map(), requirements :: map()) :: :ok | {:error, violations :: list()}

  @doc """
  Defines the callback for generating compliance reports.
  """
  @callback generate_report(params :: map()) ::
              {:ok, report :: map()} | {:error, reason :: term()}

  @doc """
  Common macro for compliance modules to reduce boilerplate.
  """
  defmacro __using__(opts) do
    compliance_type = Keyword.get(opts, :type, :generic)

    quote do
      @behaviour Blockchain.Compliance.BaseCompliance

      require Logger

      @compliance_type unquote(compliance_type)

      # Common fields for all compliance modules
      defstruct [
        :id,
        :timestamp,
        :compliance_type,
        :status,
        :metadata,
        events: [],
        violations: []
      ]

      @doc """
      Common initialization for compliance modules.
      """
      @spec init(map()) :: {:ok, struct()} | {:error, term()}
      def init(params \\ %{}) do
        {:ok,
         %__MODULE__{
           id: generate_id(),
           timestamp: DateTime.utc_now(),
           compliance_type: @compliance_type,
           status: :initialized,
           metadata: params
         }}
      end

      @doc """
      Logs a compliance event with proper tagging.
      """
      @spec log_compliance_event(map()) :: :ok
      def log_compliance_event(event) do
        enhanced_event =
          Map.merge(event, %{
            compliance_type: @compliance_type,
            module: __MODULE__,
            timestamp: DateTime.utc_now()
          })

        Logger.info("Compliance Event", enhanced_event)
        :ok
      end

      @doc """
      Validates data against compliance rules using pattern matching.
      """
      @spec validate_rules(data :: map(), rules :: list()) :: :ok | {:error, list()}
      def validate_rules(data, rules) do
        violations =
          rules
          |> Stream.map(&validate_single_rule(data, &1))
          |> Stream.filter(&match?({:error, _}, &1))
          |> Enum.map(fn {:error, violation} -> violation end)

        case violations do
          [] -> :ok
          violations -> {:error, violations}
        end
      end

      # Private helper to validate a single rule
      defp validate_single_rule(data, {field, :required}) do
        if Map.has_key?(data, field) do
          :ok
        else
          {:error, {:missing_required_field, field}}
        end
      end

      defp validate_single_rule(data, {field, {:min, min_value}}) do
        value = Map.get(data, field, 0)

        if value >= min_value do
          :ok
        else
          {:error, {:below_minimum, field, min_value}}
        end
      end

      defp validate_single_rule(data, {field, {:max, max_value}}) do
        value = Map.get(data, field, 0)

        if value <= max_value do
          :ok
        else
          {:error, {:above_maximum, field, max_value}}
        end
      end

      defp validate_single_rule(data, {field, {:in, allowed_values}}) do
        value = Map.get(data, field)

        if value in allowed_values do
          :ok
        else
          {:error, {:invalid_value, field, allowed_values}}
        end
      end

      defp validate_single_rule(_data, rule) do
        {:error, {:unknown_rule, rule}}
      end

      # Generate unique ID for compliance records
      defp generate_id do
        :crypto.strong_rand_bytes(16)
        |> Base.encode16(case: :lower)
      end

      defoverridable init: 1, validate_rules: 2
    end
  end
end
