defmodule DisterlProbe.TransactionStats do
  @moduledoc false

  def new(enabled \\ false) when is_boolean(enabled) do
    %{
      enabled: enabled,
      polls: 0,
      successes: 0,
      failures: 0,
      total_elapsed_ms: 0,
      max_elapsed_ms: 0,
      active: nil
    }
  end

  def start(%{active: nil} = stats, request_bytes, started_at)
      when is_integer(request_bytes) and request_bytes >= 0 and is_integer(started_at) do
    %{stats | polls: stats.polls + 1, active: {request_bytes, started_at}}
  end

  def succeed(%{active: {request_bytes, started_at}} = stats, response_bytes, ended_at)
      when is_integer(response_bytes) and response_bytes >= 0 and is_integer(ended_at) do
    elapsed_ms = max(ended_at - started_at, 0)
    next = update_elapsed(%{stats | successes: stats.successes + 1}, elapsed_ms)

    finish(next, %{
      outcome: :ok,
      request_bytes: request_bytes,
      response_bytes: response_bytes,
      elapsed_ms: elapsed_ms
    })
  end

  def fail(%{active: {request_bytes, started_at}} = stats, reason, ended_at)
      when is_integer(ended_at) do
    elapsed_ms = max(ended_at - started_at, 0)
    next = update_elapsed(%{stats | failures: stats.failures + 1}, elapsed_ms)

    finish(next, %{
      outcome: :error,
      reason: reason,
      request_bytes: request_bytes,
      response_bytes: nil,
      elapsed_ms: elapsed_ms
    })
  end

  def enabled?(stats), do: stats.enabled

  def trace_event?(%{outcome: :error}, _empty_packet_bytes), do: true

  def trace_event?(%{outcome: :ok} = event, empty_packet_bytes)
      when is_integer(empty_packet_bytes) and empty_packet_bytes >= 0,
      do: event.request_bytes > empty_packet_bytes or event.response_bytes > empty_packet_bytes

  defp update_elapsed(stats, elapsed_ms) do
    %{
      stats
      | total_elapsed_ms: stats.total_elapsed_ms + elapsed_ms,
        max_elapsed_ms: max(stats.max_elapsed_ms, elapsed_ms)
    }
  end

  defp finish(stats, event) do
    next = %{stats | active: nil}

    {next,
     Map.merge(event, %{
       poll: next.polls,
       successes: next.successes,
       failures: next.failures,
       max_elapsed_ms: next.max_elapsed_ms
     })}
  end
end
