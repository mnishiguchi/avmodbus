defmodule AVModbus.CRC16 do
  @moduledoc """
  polynomial `0xA001`、initial value `0xFFFF` の Modbus RTU CRC-16 を提供します。
  """

  import Bitwise

  @initial 0xFFFF
  @polynomial 0xA001

  def calculate(data) when is_binary(data) do
    calculate_bytes(:erlang.binary_to_list(data), @initial)
  end

  def append(data) when is_binary(data) do
    crc = calculate(data)
    <<data::binary, band(crc, 0xFF), band(bsr(crc, 8), 0xFF)>>
  end

  def valid?(frame) when is_binary(frame) and byte_size(frame) >= 3 do
    payload_size = byte_size(frame) - 2
    <<payload::binary-size(^payload_size), crc_low, crc_high>> = frame
    calculate(payload) == crc_low + (crc_high <<< 8)
  end

  def valid?(_frame), do: false

  defp calculate_bytes([], crc), do: crc

  defp calculate_bytes([byte | rest], crc) do
    calculate_bytes(rest, calculate_bits(bxor(crc, byte), 8))
  end

  defp calculate_bits(crc, 0), do: crc

  defp calculate_bits(crc, remaining) do
    next =
      if band(crc, 1) == 1 do
        bxor(bsr(crc, 1), @polynomial)
      else
        bsr(crc, 1)
      end

    calculate_bits(next, remaining - 1)
  end
end
