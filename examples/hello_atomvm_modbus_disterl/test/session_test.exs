defmodule DisterlProbe.SessionTest do
  use ExUnit.Case, async: true

  alias DisterlProbe.Session

  test "normalizes AtomVM's signed 32-bit random values" do
    assert Session.new_id(-1) == 4_294_967_295
    assert Session.new_id(-2_147_483_648) == 2_147_483_648
  end

  test "reserves zero as the missing-session sentinel" do
    assert Session.new_id(0) == 1
    assert Session.new_id(4_294_967_296) == 1
  end
end
