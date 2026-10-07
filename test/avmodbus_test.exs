defmodule AVModbusTest do
  use ExUnit.Case, async: true

  test "maps Modbus exception names and codes" do
    assert AVModbus.exception_name(2) == :illegal_data_address
    assert AVModbus.exception_name(7) == 7
    assert AVModbus.exception_code(:gateway_target_device_failed_to_respond) == 11
    assert AVModbus.exception_code(7) == 7

    assert_raise ArgumentError, fn -> AVModbus.exception_code(:unknown_exception) end
    assert_raise ArgumentError, fn -> AVModbus.exception_code(0) end
  end
end
