defmodule Blockchain.Compliance.SOXCompliance do
  @moduledoc """
  SOX (Sarbanes-Oxley) compliance module.
  Handles financial controls and audit requirements.
  """

  use Blockchain.Compliance.BaseCompliance, type: :sox

  @impl true
  def process_event(event) do
    with :ok <- validate_sox_event(event),
         :ok <- log_compliance_event(event),
         :ok <- check_segregation_of_duties(event) do
      {:ok,
       %{
         event_id: event.id,
         sox_compliant: true,
         timestamp: DateTime.utc_now()
       }}
    end
  end

  @impl true
  def validate(data, requirements) do
    rules = [
      {:transaction_id, :required},
      {:amount, :required},
      {:approver, :required},
      {:approval_count, {:min, requirements[:required_approvals] || 2}}
    ]

    validate_rules(data, rules)
  end

  @impl true
  def generate_report(params) do
    {:ok,
     %{
       report_type: :sox,
       period: params[:period],
       compliance_status: :compliant,
       findings: [],
       generated_at: DateTime.utc_now()
     }}
  end

  # SOX-specific validations
  defp validate_sox_event(event) do
    cond do
      not Map.has_key?(event, :financial_impact) ->
        {:error, :missing_financial_impact}

      not Map.has_key?(event, :approval_chain) ->
        {:error, :missing_approval_chain}

      true ->
        :ok
    end
  end

  defp check_segregation_of_duties(event) do
    # Ensure requester and approver are different
    if event[:requester] != event[:approver] do
      :ok
    else
      {:error, :segregation_of_duties_violation}
    end
  end
end
