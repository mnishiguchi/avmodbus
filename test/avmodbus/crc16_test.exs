defmodule AVModbus.CRC16Test do
  use ExUnit.Case, async: true

  alias AVModbus.CRC16

  test "calculates the standard function 0x03 request CRC" do
    payload = <<0x01, 0x03, 0x00, 0x00, 0x00, 0x0A>>

    assert CRC16.calculate(payload) == 0xCDC5
    assert CRC16.append(payload) == <<payload::binary, 0xC5, 0xCD>>
  end

  test "validates and rejects RTU frames" do
    assert CRC16.valid?(<<0x01, 0x03, 0x02, 0x00, 0x0A, 0x38, 0x43>>)
    refute CRC16.valid?(<<0x01, 0x03, 0x02, 0x00, 0x0B, 0x38, 0x43>>)
    refute CRC16.valid?(<<0x01, 0x03>>)
  end
end
