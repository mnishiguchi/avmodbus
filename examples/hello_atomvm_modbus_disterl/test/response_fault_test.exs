defmodule DisterlProbe.ResponseFaultTest do
  use ExUnit.Case, async: true

  alias DisterlProbe.ResponseFault

  test "drops only the configured number of accepted responses" do
    fault = ResponseFault.new([drop_responses: 2, min_payload_bytes: 96], 1_000)

    assert {:drop, fault} = ResponseFault.after_accept(fault, 96, 1_000)
    assert fault.remaining == 1
    assert fault.dropped == 1

    assert {:drop, fault} = ResponseFault.after_accept(fault, 120, 1_001)
    assert fault.remaining == 0
    assert fault.dropped == 2

    assert {:reply, ^fault} = ResponseFault.after_accept(fault, 120, 1_002)
  end

  test "does not consume the fault budget for smaller frames" do
    fault = ResponseFault.new(drop_responses: 1, min_payload_bytes: 96)

    assert {:reply, ^fault} = ResponseFault.after_accept(fault, 95, 0)
    assert {:drop, next} = ResponseFault.after_accept(fault, 96, 0)
    assert next.remaining == 0
  end

  test "does not consume the fault budget before the armed time" do
    fault = ResponseFault.new([drop_responses: 1, after_ms: 5_000], 1_000)

    assert {:reply, ^fault} = ResponseFault.after_accept(fault, 96, 5_999)
    assert {:drop, next} = ResponseFault.after_accept(fault, 96, 6_000)
    assert next.remaining == 0
  end
end
