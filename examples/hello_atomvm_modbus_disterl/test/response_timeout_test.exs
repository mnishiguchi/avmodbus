defmodule DisterlProbe.ResponseTimeoutTest do
  use ExUnit.Case, async: true

  alias DisterlProbe.ResponseTimeout

  test "keeps the handshake deadline for writes that fit one transport chunk" do
    policy = ResponseTimeout.new(500, 2_000)

    assert policy |> ResponseTimeout.observe_write(232, 232) |> ResponseTimeout.current() == 500
  end

  test "enables the bulk deadline after a multi-chunk write" do
    policy = ResponseTimeout.new(500, 2_000)
    bulk = ResponseTimeout.observe_write(policy, 233, 232)

    assert ResponseTimeout.current(bulk) == 2_000
    assert bulk |> ResponseTimeout.reset() |> ResponseTimeout.current() == 500
  end

  test "never shortens the configured initial deadline" do
    policy = ResponseTimeout.new(1_000, 500)

    assert policy |> ResponseTimeout.observe_write(233, 232) |> ResponseTimeout.current() == 1_000
  end
end
