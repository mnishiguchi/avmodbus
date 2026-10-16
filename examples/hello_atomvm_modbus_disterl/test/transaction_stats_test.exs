defmodule DisterlProbe.TransactionStatsTest do
  use ExUnit.Case, async: true

  alias DisterlProbe.TransactionStats

  test "records successful transaction sizes and elapsed time" do
    stats = TransactionStats.start(TransactionStats.new(true), 13, 100)
    {stats, event} = TransactionStats.succeed(stats, 245, 735)

    assert event == %{
             outcome: :ok,
             poll: 1,
             request_bytes: 13,
             response_bytes: 245,
             elapsed_ms: 635,
             successes: 1,
             failures: 0,
             max_elapsed_ms: 635
           }

    assert stats.active == nil
    assert stats.total_elapsed_ms == 635
    assert stats.max_elapsed_ms == 635
    assert TransactionStats.enabled?(stats)
  end

  test "aggregates failures and keeps the maximum latency" do
    stats = TransactionStats.start(TransactionStats.new(), 245, 1_000)
    {stats, first} = TransactionStats.fail(stats, :timeout, 1_500)
    stats = TransactionStats.start(stats, 13, 2_000)
    {stats, second} = TransactionStats.succeed(stats, 13, 2_100)

    assert first.outcome == :error
    assert first.reason == :timeout
    assert first.elapsed_ms == 500
    assert first.max_elapsed_ms == 500
    assert second.poll == 2
    assert stats.polls == 2
    assert stats.successes == 1
    assert stats.failures == 1
    assert stats.total_elapsed_ms == 600
    assert stats.max_elapsed_ms == 500
    refute TransactionStats.enabled?(stats)
  end

  test "traces failures and non-empty traffic but suppresses successful idle polls" do
    idle = %{outcome: :ok, request_bytes: 13, response_bytes: 13}
    request_data = %{idle | request_bytes: 14}
    response_data = %{idle | response_bytes: 245}
    failure = %{outcome: :error}

    refute TransactionStats.trace_event?(idle, 13)
    assert TransactionStats.trace_event?(request_data, 13)
    assert TransactionStats.trace_event?(response_data, 13)
    assert TransactionStats.trace_event?(failure, 13)
  end

  test "clamps elapsed time to zero if a supplied clock moves backward" do
    stats = TransactionStats.start(TransactionStats.new(), 13, 200)
    {stats, event} = TransactionStats.fail(stats, :clock_adjusted, 100)

    assert event.elapsed_ms == 0
    assert stats.total_elapsed_ms == 0
  end
end
