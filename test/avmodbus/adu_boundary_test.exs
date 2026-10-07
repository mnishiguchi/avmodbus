defmodule AVModbus.ADUBoundaryTest do
  use ExUnit.Case, async: true

  alias AVModbus.{ASCII, PDU, RTU, TCP}

  @max_pdu_size 253

  test "carries a maximum-size PDU through every transport" do
    pdu = <<100, :binary.copy(<<0xA5>>, 252)::binary>>
    assert byte_size(pdu) == @max_pdu_size

    assert {:ok, tcp} = TCP.encode(65_535, 255, pdu)
    assert byte_size(tcp) == 260
    assert TCP.decode(tcp) == {:ok, 65_535, 255, pdu, <<>>}

    assert {:ok, rtu} = RTU.encode(247, pdu)
    assert byte_size(rtu) == 256
    assert RTU.decode(rtu) == {:ok, 247, pdu}
    assert RTU.complete_silence_request(rtu) == {:ok, rtu}

    assert {:ok, ascii} = ASCII.encode(255, pdu)
    assert byte_size(ascii) == 513
    assert ASCII.split(ascii) == {:ok, ascii, <<>>}
    assert ASCII.decode(ascii) == {:ok, 255, pdu}
  end

  test "rejects a PDU one byte beyond the transport maximum" do
    oversized = :binary.copy(<<0>>, @max_pdu_size + 1)

    assert TCP.encode(0, 1, oversized) == {:error, :invalid_pdu}
    assert RTU.encode(1, oversized) == {:error, :invalid_pdu}
    assert ASCII.encode(1, oversized) == {:error, :invalid_pdu}

    assert TCP.decode(<<0::16, 0::16, 255::16, 1, oversized::binary>>) ==
             {:error, :invalid_length}

    assert RTU.decode(<<1, oversized::binary, 0, 0>>) == {:error, :frame_too_long}

    ascii = <<?:, :binary.copy("00", 256)::binary, ?\r, ?\n>>
    assert byte_size(ascii) == 515
    assert ASCII.decode(ascii) == {:error, :invalid_frame}
    assert ASCII.split(ascii) == {:skip, <<>>}
  end

  test "encodes the largest file-record request PDU" do
    values = List.duplicate(0xBEEF, 122)
    request = {:write_file_record, [{65_535, 9_878, values}]}

    assert {:ok, pdu} = PDU.encode_request(request)
    assert byte_size(pdu) == @max_pdu_size
    assert PDU.request_length(pdu) == {:ok, @max_pdu_size}
    assert PDU.decode_request(pdu) == {:ok, request}
    assert PDU.encode_response(request, :ok) == {:ok, pdu}
    assert PDU.decode_response(request, pdu) == :ok

    too_many = {:write_file_record, [{1, 0, List.duplicate(0, 123)}]}
    assert PDU.encode_request(too_many) == {:error, :invalid_quantity}
  end

  test "encodes the largest device-identification response PDU" do
    request = {:read_device_identification, :extended, 128}

    answer = %{
      conformity_level: 0x83,
      more_follows: false,
      next_object_id: 0,
      objects: [{128, :binary.copy(<<0x5A>>, 244)}]
    }

    assert {:ok, pdu} = PDU.encode_response(request, {:ok, answer})
    assert byte_size(pdu) == @max_pdu_size
    assert PDU.response_length(request, pdu) == {:ok, @max_pdu_size}
    assert PDU.decode_response(request, pdu) == {:ok, answer}

    oversized = put_in(answer.objects, [{128, :binary.copy(<<0x5A>>, 245)}])
    assert PDU.encode_response(request, {:ok, oversized}) == {:error, :invalid_handler_result}
  end

  test "enforces maximum request and response quantities at their exact edges" do
    cases = [
      {{:read_coils, 63_536, 2_000}, {:ok, List.duplicate(true, 2_000)}, 252},
      {{:read_discrete_inputs, 63_536, 2_000}, {:ok, List.duplicate(false, 2_000)}, 252},
      {{:read_holding_registers, 65_411, 125}, {:ok, List.duplicate(65_535, 125)}, 252},
      {{:read_input_registers, 65_411, 125}, {:ok, List.duplicate(0, 125)}, 252}
    ]

    for {request, result, response_size} <- cases do
      assert {:ok, request_pdu} = PDU.encode_request(request)
      assert byte_size(request_pdu) == 5
      assert {:ok, response_pdu} = PDU.encode_response(request, result)
      assert byte_size(response_pdu) == response_size
      assert PDU.decode_response(request, response_pdu) == result
    end

    assert PDU.encode_request({:read_coils, 63_535, 2_001}) == {:error, :invalid_quantity}

    assert PDU.encode_request({:read_holding_registers, 65_410, 126}) ==
             {:error, :invalid_quantity}
  end
end
