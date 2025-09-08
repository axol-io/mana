defmodule ExWire.P2P.PeerReputation do
  @moduledoc """
  Advanced peer reputation system for scoring and ranking Ethereum P2P peers
  based on their behavior, reliability, and performance metrics.
  """

  @typedoc "Peer reputation score and metadata"
  @type reputation :: %{
          score: float(),
          last_updated: DateTime.t(),
          metrics: reputation_metrics(),
          violations: [violation()],
          tags: [tag()]
        }

  @typedoc "Detailed reputation metrics"
  @type reputation_metrics :: %{
          # Connection reliability
          connection_success_rate: float(),
          avg_connection_duration: non_neg_integer(),
          total_connections: non_neg_integer(),
          last_successful_connection: DateTime.t() | nil,

          # Protocol compliance
          protocol_version_support: [integer()],
          handshake_success_rate: float(),
          message_compliance_rate: float(),

          # Performance metrics
          response_time_avg: float(),
          message_throughput: float(),
          bytes_transferred: non_neg_integer(),

          # Blockchain sync metrics
          blocks_provided: non_neg_integer(),
          invalid_blocks_sent: non_neg_integer(),
          sync_speed: float(),

          # Network behavior
          inbound_connections_accepted: non_neg_integer(),
          outbound_connections_initiated: non_neg_integer(),
          peer_recommendations_quality: float()
        }

  @typedoc "Reputation violation record"
  @type violation :: %{
          type: violation_type(),
          severity: :low | :medium | :high | :critical,
          timestamp: DateTime.t(),
          description: String.t(),
          auto_expires: boolean()
        }

  @typedoc "Types of reputation violations"
  @type violation_type ::
          :protocol_violation
          | :invalid_data
          | :excessive_disconnections
          | :spam_behavior
          | :malicious_blocks
          | :resource_abuse
          | :timeout_excessive
          | :handshake_failure

  @typedoc "Peer classification tags"
  @type tag ::
          :trusted
          | :verified
          | :fast_sync
          | :archive_node
          | :mining_pool
          | :exchange
          | :suspicious
          | :unstable
          | :new_peer
          | :bootstrap_node

  # Reputation score thresholds
  @excellent_threshold 0.8
  @good_threshold 0.6
  @acceptable_threshold 0.4
  @poor_threshold 0.2

  # Violation penalties
  @violation_penalties %{
    protocol_violation: %{low: -0.05, medium: -0.1, high: -0.2, critical: -0.5},
    invalid_data: %{low: -0.03, medium: -0.08, high: -0.15, critical: -0.3},
    excessive_disconnections: %{low: -0.02, medium: -0.05, high: -0.1, critical: -0.2},
    spam_behavior: %{low: -0.05, medium: -0.15, high: -0.3, critical: -0.6},
    malicious_blocks: %{low: -0.1, medium: -0.3, high: -0.5, critical: -1.0},
    resource_abuse: %{low: -0.03, medium: -0.08, high: -0.15, critical: -0.3},
    timeout_excessive: %{low: -0.01, medium: -0.03, high: -0.08, critical: -0.15},
    handshake_failure: %{low: -0.01, medium: -0.02, high: -0.05, critical: -0.1}
  }

  @doc """
  Calculate initial reputation score for a new peer.
  """
  @spec initial_reputation() :: reputation()
  def initial_reputation() do
    %{
      # Neutral starting score
      score: 0.5,
      last_updated: DateTime.utc_now(),
      metrics: initial_metrics(),
      violations: [],
      tags: [:new_peer]
    }
  end

  @doc """
  Update peer reputation based on a successful connection.
  """
  @spec update_for_successful_connection(reputation(), non_neg_integer()) :: reputation()
  def update_for_successful_connection(reputation, duration_seconds) do
    now = DateTime.utc_now()

    # Calculate connection quality bonus
    duration_bonus = calculate_duration_bonus(duration_seconds)

    # Update metrics
    new_metrics = %{
      reputation.metrics
      | total_connections: reputation.metrics.total_connections + 1,
        last_successful_connection: now,
        avg_connection_duration: calculate_avg_duration(reputation.metrics, duration_seconds)
    }

    # Update success rate
    updated_metrics = update_connection_success_rate(new_metrics, true)

    # Calculate new score
    base_improvement = 0.05
    quality_multiplier = min(duration_bonus, 2.0)
    score_improvement = base_improvement * quality_multiplier

    new_score = min(1.0, reputation.score + score_improvement)

    %{
      reputation
      | score: new_score,
        last_updated: now,
        metrics: updated_metrics,
        tags: update_tags_for_successful_connection(reputation.tags, duration_seconds)
    }
  end

  @doc """
  Update peer reputation based on a failed connection.
  """
  @spec update_for_failed_connection(reputation(), atom()) :: reputation()
  def update_for_failed_connection(reputation, _reason) do
    now = DateTime.utc_now()

    # Update metrics
    new_metrics = %{
      reputation.metrics
      | total_connections: reputation.metrics.total_connections + 1
    }

    updated_metrics = update_connection_success_rate(new_metrics, false)

    # Apply penalty based on failure reason
    penalty =
      case reason do
        :timeout -> -0.02
        :protocol_error -> -0.05
        :handshake_failed -> -0.03
        :refused -> -0.01
        _ -> -0.02
      end

    new_score = max(0.0, reputation.score + penalty)

    %{
      reputation
      | score: new_score,
        last_updated: now,
        metrics: updated_metrics,
        tags: update_tags_for_failed_connection(reputation.tags, _reason)
    }
  end

  @doc """
  Record a reputation violation for a peer.
  """
  @spec record_violation(
          reputation(),
          violation_type(),
          :low | :medium | :high | :critical,
          String.t()
        ) :: reputation()
  def record_violation(reputation, violation_type, severity, description) do
    now = DateTime.utc_now()

    violation = %{
      type: violation_type,
      severity: severity,
      timestamp: now,
      description: description,
      auto_expires: should_auto_expire?(violation_type, severity)
    }

    # Apply penalty
    penalty = get_violation_penalty(violation_type, severity)
    new_score = max(0.0, reputation.score + penalty)

    # Add violation to history
    new_violations = [violation | reputation.violations]

    %{
      reputation
      | score: new_score,
        last_updated: now,
        violations: new_violations,
        tags: update_tags_for_violation(reputation.tags, violation_type, severity)
    }
  end

  @doc """
  Update peer reputation based on protocol performance metrics.
  """
  @spec update_for_protocol_performance(reputation(), %{
          response_time: float(),
          message_count: non_neg_integer(),
          bytes_transferred: non_neg_integer(),
          protocol_violations: non_neg_integer()
        }) :: reputation()
  def update_for_protocol_performance(reputation, performance_data) do
    now = DateTime.utc_now()

    # Update performance metrics
    new_metrics = %{
      reputation.metrics
      | response_time_avg:
          calculate_avg_response_time(reputation.metrics, performance_data.response_time),
        message_throughput:
          calculate_message_throughput(reputation.metrics, performance_data.message_count),
        bytes_transferred:
          reputation.metrics.bytes_transferred + performance_data.bytes_transferred
    }

    # Calculate performance score adjustment
    performance_score = calculate_performance_score(performance_data)
    # Small adjustment based on performance
    score_adjustment = (performance_score - 0.5) * 0.02

    new_score = max(0.0, min(1.0, reputation.score + score_adjustment))

    %{
      reputation
      | score: new_score,
        last_updated: now,
        metrics: new_metrics,
        tags: update_tags_for_performance(reputation.tags, performance_score)
    }
  end

  @doc """
  Clean up expired violations and apply reputation recovery.
  """
  @spec cleanup_expired_violations(reputation()) :: reputation()
  def cleanup_expired_violations(reputation) do
    now = DateTime.utc_now()

    # Remove expired violations (older than 24 hours for auto-expiring)
    active_violations =
      Enum.filter(reputation.violations, fn violation ->
        if violation.auto_expires do
          # 24 hours
          DateTime.diff(now, violation.timestamp, :second) < 86400
        else
          # Keep non-auto-expiring violations
          true
        end
      end)

    # Apply reputation recovery if violations were removed
    recovery_amount = (length(reputation.violations) - length(active_violations)) * 0.01
    new_score = min(1.0, reputation.score + recovery_amount)

    %{reputation | score: new_score, last_updated: now, violations: active_violations}
  end

  @doc """
  Get peer reputation classification.
  """
  @spec classify_peer(reputation()) :: :excellent | :good | :acceptable | :poor | :banned
  def classify_peer(reputation) do
    cond do
      reputation.score >= @excellent_threshold -> :excellent
      reputation.score >= @good_threshold -> :good
      reputation.score >= @acceptable_threshold -> :acceptable
      reputation.score >= @poor_threshold -> :poor
      true -> :banned
    end
  end

  @doc """
  Check if peer should be prioritized for connections.
  """
  @spec should_prioritize?(reputation()) :: boolean()
  def should_prioritize?(reputation) do
    reputation.score >= @good_threshold and
      not Enum.member?(reputation.tags, :suspicious) and
      not Enum.member?(reputation.tags, :unstable)
  end

  @doc """
  Check if peer should be avoided for connections.
  """
  @spec should_avoid?(reputation()) :: boolean()
  def should_avoid?(reputation) do
    reputation.score < @acceptable_threshold or
      Enum.member?(reputation.tags, :suspicious) or
      has_recent_critical_violations?(reputation)
  end

  # Private helper functions

  defp initial_metrics() do
    %{
      connection_success_rate: 0.0,
      avg_connection_duration: 0,
      total_connections: 0,
      last_successful_connection: nil,
      protocol_version_support: [],
      handshake_success_rate: 0.0,
      message_compliance_rate: 1.0,
      response_time_avg: 0.0,
      message_throughput: 0.0,
      bytes_transferred: 0,
      blocks_provided: 0,
      invalid_blocks_sent: 0,
      sync_speed: 0.0,
      inbound_connections_accepted: 0,
      outbound_connections_initiated: 0,
      peer_recommendations_quality: 0.5
    }
  end

  defp calculate_duration_bonus(duration_seconds) do
    cond do
      # 1+ hour connection
      duration_seconds >= 3600 -> 1.5
      # 30+ minute connection
      duration_seconds >= 1800 -> 1.2
      # 10+ minute connection
      duration_seconds >= 600 -> 1.1
      # 1+ minute connection
      duration_seconds >= 60 -> 1.0
      # Short connection
      true -> 0.8
    end
  end

  defp calculate_avg_duration(metrics, new_duration) do
    if metrics.total_connections > 0 do
      (metrics.avg_connection_duration * (metrics.total_connections - 1) + new_duration) /
        metrics.total_connections
    else
      new_duration
    end
  end

  defp update_connection_success_rate(metrics, success) do
    total = metrics.total_connections

    if total > 0 do
      current_successes = trunc(metrics.connection_success_rate * (total - 1))
      new_successes = if success, do: current_successes + 1, else: current_successes
      new_rate = new_successes / total
      %{metrics | connection_success_rate: new_rate}
    else
      rate = if success, do: 1.0, else: 0.0
      %{metrics | connection_success_rate: rate}
    end
  end

  defp update_tags_for_successful_connection(tags, duration) do
    tags = List.delete(tags, :new_peer)

    if duration >= 3600 do
      [:trusted | tags] |> Enum.uniq()
    else
      tags
    end
  end

  defp update_tags_for_failed_connection(tags, _reason) do
    case reason do
      :timeout -> [:unstable | tags] |> Enum.uniq()
      :protocol_error -> [:suspicious | tags] |> Enum.uniq()
      _ -> tags
    end
  end

  defp update_tags_for_violation(tags, violation_type, severity) do
    new_tags =
      case {violation_type, severity} do
        {_, :critical} -> [:suspicious | tags]
        {:malicious_blocks, _} -> [:suspicious | tags]
        {:spam_behavior, :high} -> [:suspicious | tags]
        {:excessive_disconnections, _} -> [:unstable | tags]
        _ -> tags
      end

    Enum.uniq(new_tags)
  end

  defp update_tags_for_performance(tags, performance_score) do
    cond do
      performance_score >= 0.8 -> [:fast_sync | List.delete(tags, :unstable)] |> Enum.uniq()
      performance_score <= 0.2 -> [:unstable | tags] |> Enum.uniq()
      true -> tags
    end
  end

  defp should_auto_expire?(violation_type, severity) do
    case {violation_type, severity} do
      # Critical violations don't auto-expire
      {_, :critical} -> false
      # Malicious behavior doesn't auto-expire
      {:malicious_blocks, _} -> false
      # High-severity spam doesn't auto-expire
      {:spam_behavior, :high} -> false
      # Most violations auto-expire
      _ -> true
    end
  end

  defp get_violation_penalty(violation_type, severity) do
    @violation_penalties
    |> Map.get(violation_type, %{low: -0.02, medium: -0.05, high: -0.1, critical: -0.2})
    |> Map.get(severity, -0.02)
  end

  defp calculate_avg_response_time(metrics, new_response_time) do
    if metrics.response_time_avg > 0 do
      metrics.response_time_avg * 0.9 + new_response_time * 0.1
    else
      new_response_time
    end
  end

  defp calculate_message_throughput(metrics, message_count) do
    # Simple throughput calculation (messages per unit time)
    if metrics.message_throughput > 0 do
      metrics.message_throughput * 0.9 + message_count * 0.1
    else
      message_count
    end
  end

  defp calculate_performance_score(performance_data) do
    # Normalize and combine different performance metrics
    # 5s timeout
    response_score = max(0.0, min(1.0, 1.0 - performance_data.response_time / 5000.0))
    # Normalize to 100 messages
    throughput_score = min(1.0, performance_data.message_count / 100.0)
    violation_penalty = performance_data.protocol_violations * 0.1

    max(0.0, min(1.0, (response_score + throughput_score) / 2.0 - violation_penalty))
  end

  defp has_recent_critical_violations?(reputation) do
    now = DateTime.utc_now()

    Enum.any?(reputation.violations, fn violation ->
      # Within last hour
      violation.severity == :critical and
        DateTime.diff(now, violation.timestamp, :second) < 3600
    end)
  end
end
