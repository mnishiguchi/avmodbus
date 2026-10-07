defmodule AVModbus.ASCII do
  @moduledoc """
  Modbus ASCII の framing、LRC validation、stream extraction を提供します。

  binary の各 byte を 2 文字の hexadecimal で表し、`:` から CR + delimiter までを
  1 frame として扱います。Change ASCII Input Delimiter 用に custom delimiter も指定できます。
  """

  import Bitwise

  @max_frame_size 513

  @doc "`data` の Modbus LRC (Longitudinal Redundancy Check) を返します。"
  @spec lrc(binary()) :: byte()
  def lrc(data) when is_binary(data), do: band(0x100 - rem(sum(data, 0), 0x100), 0xFF)

  @doc "unit id と PDU を完全な Modbus ASCII frame に encode します。"
  @spec encode(0..255, binary(), byte()) :: {:ok, binary()} | {:error, term()}
  def encode(unit_id, pdu, delimiter \\ ?\n)

  def encode(unit_id, pdu, delimiter)
      when is_integer(unit_id) and unit_id >= 0 and unit_id <= 255 and is_binary(pdu) and
             byte_size(pdu) >= 1 and byte_size(pdu) <= 253 and is_integer(delimiter) and
             delimiter >= 0 and delimiter <= 255 do
    data = <<unit_id, pdu::binary>>
    bytes = <<data::binary, lrc(data)>>
    hex = encode_hex(bytes, <<>>)
    {:ok, <<?:, hex::binary, ?\r, delimiter>>}
  end

  def encode(unit_id, _pdu, _delimiter)
      when not is_integer(unit_id) or unit_id < 0 or unit_id > 255,
      do: {:error, :invalid_unit_id}

  def encode(_unit_id, pdu, _delimiter)
      when not is_binary(pdu) or byte_size(pdu) < 1 or byte_size(pdu) > 253,
      do: {:error, :invalid_pdu}

  def encode(_unit_id, _pdu, _delimiter), do: {:error, :invalid_delimiter}

  @doc "完全な Modbus ASCII frame を decode し、LRC を検証します。"
  @spec decode(binary()) :: {:ok, 0..255, binary()} | {:error, :invalid_lrc | :invalid_frame}
  def decode(frame)
      when is_binary(frame) and byte_size(frame) >= 9 and byte_size(frame) <= @max_frame_size do
    hex_size = byte_size(frame) - 3

    case frame do
      <<?:, hex::binary-size(hex_size), ?\r, _delimiter>> ->
        decode_frame_hex(hex)

      _other ->
        {:error, :invalid_frame}
    end
  end

  def decode(_frame), do: {:error, :invalid_frame}

  @doc """
  stream buffer の先頭から 1 frame を取り出します。

  `{:ok, frame, rest}`、`:more`、`{:skip, rest}` のいずれかを返します。
  incomplete frame 内で新しい `:` を検出した場合は、そこから次の frame として再同期します。
  """
  @spec split(binary(), byte()) :: {:ok, binary(), binary()} | {:skip, binary()} | :more
  def split(buffer, delimiter \\ ?\n)

  def split(<<>>, delimiter) when is_integer(delimiter) and delimiter >= 0 and delimiter <= 255,
    do: :more

  def split(<<?:, _rest::binary>> = buffer, delimiter)
      when is_integer(delimiter) and delimiter >= 0 and delimiter <= 255,
      do: scan_frame(buffer, tail(buffer), delimiter, 0)

  def split(<<_byte, rest::binary>>, delimiter)
      when is_integer(delimiter) and delimiter >= 0 and delimiter <= 255 do
    case find_start(rest) do
      :none -> {:skip, <<>>}
      frame_start -> {:skip, frame_start}
    end
  end

  def split(_buffer, _delimiter), do: {:skip, <<>>}

  defp decode_frame_hex(hex) do
    with {:ok, bytes} <- decode_hex(hex, []),
         true <- byte_size(bytes) >= 3 do
      pdu_size = byte_size(bytes) - 2
      <<unit_id, pdu::binary-size(pdu_size), checksum>> = bytes
      data = <<unit_id, pdu::binary>>

      if lrc(data) == checksum,
        do: {:ok, unit_id, pdu},
        else: {:error, :invalid_lrc}
    else
      _error -> {:error, :invalid_frame}
    end
  end

  defp sum(<<byte, rest::binary>>, result), do: sum(rest, result + byte)
  defp sum(<<>>, result), do: result

  defp encode_hex(<<>>, result), do: result

  defp encode_hex(<<byte, rest::binary>>, result) do
    high = hex_digit(byte >>> 4)
    low = hex_digit(band(byte, 0x0F))
    encode_hex(rest, <<result::binary, high, low>>)
  end

  defp hex_digit(value) when value < 10, do: ?0 + value
  defp hex_digit(value), do: ?A + value - 10

  defp decode_hex(<<>>, bytes),
    do: {:ok, :erlang.list_to_binary(reverse(bytes, []))}

  defp decode_hex(<<high, low, rest::binary>>, bytes) do
    with {:ok, high_value} <- hex_value(high),
         {:ok, low_value} <- hex_value(low) do
      decode_hex(rest, [(high_value <<< 4) + low_value | bytes])
    end
  end

  defp decode_hex(_odd, _bytes), do: {:error, :invalid_hex}

  defp hex_value(value) when value >= ?0 and value <= ?9, do: {:ok, value - ?0}
  defp hex_value(value) when value >= ?A and value <= ?F, do: {:ok, value - ?A + 10}
  defp hex_value(value) when value >= ?a and value <= ?f, do: {:ok, value - ?a + 10}
  defp hex_value(_value), do: {:error, :invalid_hex}

  defp find_start(<<?:, _rest::binary>> = buffer), do: buffer
  defp find_start(<<_byte, rest::binary>>), do: find_start(rest)
  defp find_start(<<>>), do: :none

  defp scan_frame(buffer, <<delimiter, _rest::binary>>, delimiter, position) do
    frame_size = position + 2

    if frame_size <= @max_frame_size do
      <<frame::binary-size(frame_size), rest::binary>> = buffer
      {:ok, frame, rest}
    else
      {:skip, tail_after_delimiter(buffer, frame_size)}
    end
  end

  defp scan_frame(_buffer, <<?:, _rest::binary>> = next, _delimiter, _position),
    do: {:skip, next}

  defp scan_frame(buffer, <<_byte, rest::binary>>, delimiter, position),
    do: scan_frame(buffer, rest, delimiter, position + 1)

  defp scan_frame(buffer, <<>>, _delimiter, _position) do
    if byte_size(buffer) < @max_frame_size, do: :more, else: {:skip, <<>>}
  end

  defp tail(<<?:, rest::binary>>), do: rest

  defp tail_after_delimiter(buffer, frame_size) do
    <<_frame::binary-size(frame_size), rest::binary>> = buffer
    rest
  end

  defp reverse([], result), do: result
  defp reverse([value | rest], result), do: reverse(rest, [value | result])
end
