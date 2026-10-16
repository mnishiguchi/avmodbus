defmodule DisterlProbe.PingStats do
  @moduledoc false

  def new do
    %{
      successes: 0,
      timeouts: 0,
      total_rtt_ms: 0,
      min_rtt_ms: nil,
      max_rtt_ms: 0
    }
  end

  def record_success(stats, rtt_ms) when is_integer(rtt_ms) and rtt_ms >= 0 do
    %{
      stats
      | successes: stats.successes + 1,
        total_rtt_ms: stats.total_rtt_ms + rtt_ms,
        min_rtt_ms: min_rtt(stats.min_rtt_ms, rtt_ms),
        max_rtt_ms: max(stats.max_rtt_ms, rtt_ms)
    }
  end

  def record_timeout(stats), do: %{stats | timeouts: stats.timeouts + 1}

  def summary(%{successes: successes} = stats) when successes > 0 do
    %{
      successes: successes,
      timeouts: stats.timeouts,
      min_rtt_ms: stats.min_rtt_ms,
      average_rtt_ms: div(stats.total_rtt_ms, successes),
      max_rtt_ms: stats.max_rtt_ms
    }
  end

  defp min_rtt(nil, rtt_ms), do: rtt_ms
  defp min_rtt(min_rtt_ms, rtt_ms), do: min(min_rtt_ms, rtt_ms)
end
