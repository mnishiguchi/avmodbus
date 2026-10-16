defmodule DisterlProbe.PayloadTest do
  use ExUnit.Case, async: true

  alias DisterlProbe.Payload

  test "builds deterministic payloads at exact requested sizes" do
    for size <- [0, 1, 15, 16, 17, 231, 232, 233, 4_096] do
      payload = Payload.build(size)
      assert byte_size(payload) == size
      assert Payload.valid?(payload)
      assert payload == Payload.build(size)
    end
  end

  test "rejects content corruption without changing the payload size" do
    payload = Payload.build(32)
    <<first, rest::binary>> = payload
    refute Payload.valid?(<<Bitwise.bxor(first, 0xFF), rest::binary>>)
  end
end
