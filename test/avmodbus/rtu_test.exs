defmodule AVModbus.RTUTest do
  use ExUnit.Case, async: true

  alias AVModbus.RTU

  test "encodes and decodes a function 0x03 frame" do
    pdu = <<0x03, 0x00, 0x00, 0x00, 0x0A>>
    frame = <<0x01, 0x03, 0x00, 0x00, 0x00, 0x0A, 0xC5, 0xCD>>

    assert RTU.encode(1, pdu) == {:ok, frame}
    assert RTU.decode(frame) == {:ok, 1, pdu}
  end

  test "rejects invalid frames and reserved unit ids" do
    assert RTU.decode(<<0x01, 0x03, 0x02, 0x00, 0x0B, 0x38, 0x43>>) ==
             {:error, :invalid_crc}

    assert RTU.decode(<<0x01, 0x03, 0x00>>) == {:error, :frame_too_short}
    assert RTU.encode(248, <<0x03>>) == {:error, :invalid_unit_id}
  end

  test "extracts a response while preserving following bytes" do
    request = {:read_holding_registers, 0, 1}
    {:ok, frame} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)

    assert RTU.split_response(binary_part(frame, 0, 4), 1, request) == :more

    assert RTU.split_response(frame <> <<0xAA, 0xBB>>, 1, request) ==
             {:ok, frame, <<0xAA, 0xBB>>}
  end

  test "identifies leading noise and invalid CRC as bytes to skip" do
    request = {:read_holding_registers, 0, 1}
    {:ok, frame} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    prefix_size = byte_size(frame) - 2
    <<prefix::binary-size(prefix_size), crc_low, crc_high>> = frame

    assert RTU.split_response(<<0xFF, frame::binary>>, 1, request) == :skip
    assert RTU.split_response(<<prefix::binary, crc_low, crc_high + 1>>, 1, request) == :skip
  end

  test "extracts an exception response" do
    request = {:read_holding_registers, 0, 1}
    {:ok, frame} = RTU.encode(1, <<0x83, 0x02>>)

    assert RTU.split_response(frame, 1, request) == {:ok, frame, <<>>}
  end

  test "extracts requests and preserves following frames" do
    {:ok, first} = RTU.encode(3, <<0x03, 0x00, 0x00, 0x00, 0x01>>)
    {:ok, second} = RTU.encode(4, <<0x06, 0x00, 0x02, 0x00, 0x2A>>)

    assert RTU.split_request(binary_part(first, 0, 4)) == :more
    assert RTU.split_request(first <> second) == {:ok, first, second}
    assert RTU.split_request(<<0xFF, first::binary>>) == :skip
  end

  test "validates a silence-delimited custom request after leading noise" do
    {:ok, frame} = RTU.encode(3, <<100, 1, 2, 3>>)

    assert RTU.split_request(frame) == :unknown
    assert RTU.complete_silence_request(<<0xFF, frame::binary>>) == {:ok, frame}
  end

  test "calculates the recommended RTU frame gap" do
    assert RTU.frame_gap_us(9_600) == 4_011
    assert RTU.frame_gap_us(19_200) == 2_006
    assert RTU.frame_gap_us(115_200) == 1_750
  end

  test "validates a silence-delimited response after leading noise" do
    request = {:custom, 100, <<1>>}
    {:ok, frame} = RTU.encode(3, <<100, 9, 8>>)

    assert RTU.complete_silence_response(<<0xFF, frame::binary>>, 3, request) ==
             {:ok, frame}

    assert RTU.complete_silence_response(frame, 4, request) == {:error, :frame_too_short}
  end
end
