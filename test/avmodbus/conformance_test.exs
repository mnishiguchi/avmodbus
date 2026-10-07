defmodule AVModbus.ConformanceTest do
  use ExUnit.Case, async: true

  alias AVModbus.PDU

  @application_examples [
    {{:read_coils, 19, 19}, "01 0013 0013", "01 03 CD6B05",
     {:ok,
      [true, false, true, true, false, false, true, true] ++
        [true, true, false, true, false, true, true, false] ++ [true, false, true]}},
    {{:read_discrete_inputs, 196, 22}, "02 00C4 0016", "02 03 ACDB35",
     {:ok,
      [false, false, true, true, false, true, false, true] ++
        [true, true, false, true, true, false, true, true] ++
        [true, false, true, false, true, true]}},
    {{:read_holding_registers, 107, 3}, "03 006B 0003", "03 06 022B 0000 0064",
     {:ok, [555, 0, 100]}},
    {{:read_input_registers, 8, 1}, "04 0008 0001", "04 02 000A", {:ok, [10]}},
    {{:write_single_coil, 172, true}, "05 00AC FF00", "05 00AC FF00", :ok},
    {{:write_single_register, 1, 3}, "06 0001 0003", "06 0001 0003", :ok},
    {:read_exception_status, "07", "07 6D", {:ok, 0x6D}},
    {{:diagnostics, 0, [0xA537]}, "08 0000 A537", "08 0000 A537", {:ok, [0xA537]}},
    {:get_comm_event_counter, "0B", "0B FFFF 0108", {:ok, %{status: 0xFFFF, event_count: 264}}},
    {:get_comm_event_log, "0C", "0C 08 0000 0108 0121 20 00",
     {:ok, %{status: 0, event_count: 264, message_count: 289, events: [0x20, 0]}}},
    {{:write_multiple_coils, 19,
      [true, false, true, true, false, false, true, true, true, false]}, "0F 0013 000A 02 CD01",
     "0F 0013 000A", :ok},
    {{:write_multiple_registers, 1, [10, 258]}, "10 0001 0002 04 000A 0102", "10 0001 0002", :ok},
    {:report_server_id, "11", "11 03 01 FF 00", {:ok, <<1, 0xFF, 0>>}},
    {{:read_file_record, [{4, 1, 2}, {3, 9, 2}]}, "14 0E 06 0004 0001 0002 06 0003 0009 0002",
     "14 0C 05 06 0DFE 0020 05 06 33CD 0040", {:ok, [[0x0DFE, 0x20], [0x33CD, 0x40]]}},
    {{:write_file_record, [{4, 7, [0x06AF, 0x04BE, 0x100D]}]},
     "15 0D 06 0004 0007 0003 06AF 04BE 100D", "15 0D 06 0004 0007 0003 06AF 04BE 100D", :ok},
    {{:mask_write_register, 4, 0xF2, 0x25}, "16 0004 00F2 0025", "16 0004 00F2 0025", :ok},
    {{:read_write_multiple_registers, 3, 6, 14, [0xFF, 0xFF, 0xFF]},
     "17 0003 0006 000E 0003 06 00FF 00FF 00FF", "17 0C 00FE 0ACD 0001 0003 000D 00FF",
     {:ok, [0xFE, 0x0ACD, 1, 3, 0x0D, 0xFF]}},
    {{:read_fifo_queue, 0x04DE}, "18 04DE", "18 0006 0002 01B8 1284", {:ok, [440, 4740]}}
  ]

  test "application protocol V1.1b3 examples round-trip at both endpoints" do
    for {request, request_hex, response_hex, result} <- @application_examples do
      request_pdu = hex(request_hex)
      response_pdu = hex(response_hex)

      assert PDU.encode_request(request) == {:ok, request_pdu}, inspect(request)
      assert PDU.decode_request(request_pdu) == {:ok, request}, inspect(request)
      assert PDU.decode_response(request, response_pdu) == result, inspect(request)
      assert PDU.encode_response(request, result) == {:ok, response_pdu}, inspect(request)
    end
  end

  test "read device identification V1.1b3 example round-trips" do
    request = {:read_device_identification, :basic, 0}
    request_pdu = hex("2B 0E 01 00")
    objects = [{0, "Company identification"}, {1, "Product code XX"}, {2, "V2.11"}]

    response_pdu =
      hex("2B 0E 01 01 00 00 03") <>
        <<0, 22, "Company identification", 1, 15, "Product code XX", 2, 5, "V2.11">>

    result =
      {:ok, %{conformity_level: 1, more_follows: false, next_object_id: 0, objects: objects}}

    assert PDU.encode_request(request) == {:ok, request_pdu}
    assert PDU.decode_request(request_pdu) == {:ok, request}
    assert PDU.decode_response(request, response_pdu) == result
    assert PDU.encode_response(request, result) == {:ok, response_pdu}
  end

  test "malformed application requests map to specification exceptions" do
    illegal_values = [
      <<1, 0::16, 0::16>>,
      <<1, 0::16, 2_001::16>>,
      <<2, 0::16, 2_001::16>>,
      <<3, 0::16, 0::16>>,
      <<3, 0::16, 126::16>>,
      <<4, 0::16, 126::16>>,
      <<15, 0::16, 1_969::16, 247, 0::1976>>,
      <<16, 0::16, 124::16, 248, 0::1984>>,
      <<23, 0::16, 126::16, 0::16, 1::16, 2, 0::16>>,
      <<23, 0::16, 1::16, 0::16, 122::16, 244, 0::1952>>,
      <<1, 0::16, 1::16, 0>>,
      <<1, 0::16>>,
      <<5, 0::16, 0x1234::16>>,
      <<6, 0::16>>,
      <<7, 0>>,
      <<8, 0::16, 1>>,
      <<15, 0::16, 10::16, 1, 0>>,
      <<15, 0::16, 10::16, 2, 0>>,
      <<16, 0::16, 2::16, 3, 0, 0, 0>>,
      <<16, 0::16, 2::16, 4, 0, 0, 0>>,
      <<20, 6, 6, 0, 1, 0, 0, 0>>,
      <<20, 7, 6, 0, 1, 0, 0, 0, 0>>,
      <<21, 9, 6, 0, 1, 0, 0, 0, 2, 0, 0>>,
      <<22, 0::16, 0::16>>,
      <<24, 0>>,
      <<43, 14, 5, 0>>,
      <<43, 14, 1>>,
      <<43>>
    ]

    for pdu <- illegal_values do
      assert PDU.decode_request(pdu) == {:error, :illegal_data_value}, inspect(pdu)
    end

    illegal_addresses = [
      <<20, 7, 7, 1::16, 0::16, 1::16>>,
      <<20, 7, 6, 0::16, 0::16, 1::16>>,
      <<20, 7, 6, 1::16, 9_999::16, 2::16>>,
      <<21, 9, 6, 0::16, 0::16, 1::16, 5::16>>
    ]

    for pdu <- illegal_addresses do
      assert PDU.decode_request(pdu) == {:error, :illegal_data_address}, inspect(pdu)
    end
  end

  test "client rejects response shapes that do not match their requests" do
    invalid_responses = [
      {{:read_coils, 0, 9}, <<1, 1, 0>>},
      {{:read_coils, 0, 8}, <<1, 1, 0, 0>>},
      {{:read_holding_registers, 0, 2}, <<3, 2, 0, 0>>},
      {{:read_holding_registers, 0, 2}, <<3, 4, 0, 0, 0>>},
      {{:read_write_multiple_registers, 0, 2, 0, [1]}, <<23, 2, 0, 0>>},
      {{:read_fifo_queue, 0}, <<24, 0, 6, 0, 1, 0, 0>>},
      {{:read_fifo_queue, 0}, <<24, 0, 66, 0, 32, 0::512>>},
      {{:read_file_record, [{1, 0, 2}]}, <<20, 4, 3, 6, 0, 0>>},
      {{:read_file_record, [{1, 0, 1}, {1, 5, 1}]}, <<20, 4, 3, 6, 0, 0>>},
      {:get_comm_event_log, <<12, 7, 0::48>>},
      {:report_server_id, <<17, 3, 1, 2>>}
    ]

    for {request, pdu} <- invalid_responses do
      assert PDU.decode_response(request, pdu) == {:error, {:invalid_response, pdu}}, inspect(pdu)
    end
  end

  defp hex(text) do
    text
    |> String.replace(" ", "")
    |> Base.decode16!()
  end
end
