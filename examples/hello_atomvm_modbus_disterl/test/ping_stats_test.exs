defmodule DisterlProbe.PingStatsTest do
  use ExUnit.Case, async: true

  alias DisterlProbe.PingStats

  test "summarizes successful round-trip times" do
    stats =
      PingStats.new()
      |> PingStats.record_success(7_889)
      |> PingStats.record_success(7_400)
      |> PingStats.record_success(8_100)

    assert PingStats.summary(stats) == %{
             successes: 3,
             timeouts: 0,
             min_rtt_ms: 7_400,
             average_rtt_ms: 7_796,
             max_rtt_ms: 8_100
           }
  end

  test "counts retries separately from successful messages" do
    stats =
      PingStats.new()
      |> PingStats.record_timeout()
      |> PingStats.record_timeout()
      |> PingStats.record_success(900)

    assert PingStats.summary(stats).timeouts == 2
    assert PingStats.summary(stats).successes == 1
  end

  test "clamps neither a zero RTT nor a large RTT" do
    stats =
      PingStats.new()
      |> PingStats.record_success(0)
      |> PingStats.record_success(60_000)

    assert PingStats.summary(stats).min_rtt_ms == 0
    assert PingStats.summary(stats).max_rtt_ms == 60_000
    assert PingStats.summary(stats).average_rtt_ms == 30_000
  end
end
