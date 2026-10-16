defmodule DisterlProbe.GenServerFallbackTest do
  use ExUnit.Case, async: true

  alias DisterlProbe.{Mailbox, ModbusUART, PingPong}

  test "explicit fallback callbacks return deterministic stop reasons" do
    assert Mailbox.handle_cast(:unexpected, :state) ==
             {:stop, {:bad_cast, :unexpected}, :state}

    assert ModbusUART.handle_cast(:unexpected, :state) ==
             {:stop, {:bad_cast, :unexpected}, :state}

    assert PingPong.handle_call(:unexpected, :from, :state) ==
             {:stop, {:bad_call, :unexpected}, :state}

    assert PingPong.handle_cast(:unexpected, :state) ==
             {:stop, {:bad_cast, :unexpected}, :state}
  end
end
