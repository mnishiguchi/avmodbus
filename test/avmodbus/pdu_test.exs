defmodule AVModbus.PDUTest do
  use ExUnit.Case, async: true

  alias AVModbus.PDU

  test "encodes and decodes the common read functions" do
    cases = [
      {
        {:read_coils, 19, 19},
        <<0x01, 0x00, 0x13, 0x00, 0x13>>,
        <<0x01, 0x03, 0xCD, 0x6B, 0x05>>,
        [true, false, true, true, false, false, true, true] ++
          [true, true, false, true, false, true, true, false] ++
          [true, false, true]
      },
      {
        {:read_discrete_inputs, 196, 22},
        <<0x02, 0x00, 0xC4, 0x00, 0x16>>,
        <<0x02, 0x03, 0xAC, 0xDB, 0x35>>,
        [false, false, true, true, false, true, false, true] ++
          [true, true, false, true, true, false, true, true] ++
          [true, false, true, false, true, true]
      },
      {
        {:read_holding_registers, 107, 3},
        <<0x03, 0x00, 0x6B, 0x00, 0x03>>,
        <<0x03, 0x06, 0x02, 0x2B, 0x00, 0x00, 0x00, 0x64>>,
        [555, 0, 100]
      },
      {
        {:read_input_registers, 8, 1},
        <<0x04, 0x00, 0x08, 0x00, 0x01>>,
        <<0x04, 0x02, 0x00, 0x0A>>,
        [10]
      }
    ]

    for {request, request_pdu, response_pdu, result} <- cases do
      assert PDU.encode_request(request) == {:ok, request_pdu}
      assert PDU.decode_response(request, response_pdu) == {:ok, result}
    end
  end

  test "encodes and verifies the common write functions" do
    cases = [
      {
        {:write_single_coil, 172, true},
        <<0x05, 0x00, 0xAC, 0xFF, 0x00>>,
        <<0x05, 0x00, 0xAC, 0xFF, 0x00>>
      },
      {
        {:write_single_register, 1, 3},
        <<0x06, 0x00, 0x01, 0x00, 0x03>>,
        <<0x06, 0x00, 0x01, 0x00, 0x03>>
      },
      {
        {:write_multiple_coils, 19,
         [true, false, true, true, false, false, true, true, true, false]},
        <<0x0F, 0x00, 0x13, 0x00, 0x0A, 0x02, 0xCD, 0x01>>,
        <<0x0F, 0x00, 0x13, 0x00, 0x0A>>
      },
      {
        {:write_multiple_registers, 1, [10, 258]},
        <<0x10, 0x00, 0x01, 0x00, 0x02, 0x04, 0x00, 0x0A, 0x01, 0x02>>,
        <<0x10, 0x00, 0x01, 0x00, 0x02>>
      }
    ]

    for {request, request_pdu, response_pdu} <- cases do
      assert PDU.encode_request(request) == {:ok, request_pdu}
      assert PDU.decode_response(request, response_pdu) == :ok
    end
  end

  test "encodes and decodes mask write register" do
    request = {:mask_write_register, 4, 0x00F2, 0x0025}
    pdu = <<0x16, 0x00, 0x04, 0x00, 0xF2, 0x00, 0x25>>

    assert PDU.encode_request(request) == {:ok, pdu}
    assert PDU.decode_response(request, pdu) == :ok

    invalid = <<0x16, 0x00, 0x04, 0x00, 0xF2, 0x00, 0x24>>
    assert PDU.decode_response(request, invalid) == {:error, {:invalid_response, invalid}}
  end

  test "encodes and decodes read/write multiple registers" do
    request = {:read_write_multiple_registers, 3, 6, 14, [0x00FF, 0x00FF, 0x00FF]}

    assert PDU.encode_request(request) ==
             {:ok,
              <<0x17, 0x00, 0x03, 0x00, 0x06, 0x00, 0x0E, 0x00, 0x03, 0x06, 0x00, 0xFF, 0x00,
                0xFF, 0x00, 0xFF>>}

    assert PDU.decode_response(
             request,
             <<0x17, 0x0C, 0x00, 0x00, 0x00, 0xFE, 0x00, 0x00, 0x00, 0xFE, 0x00, 0x00, 0x00,
               0xFE>>
           ) == {:ok, [0, 0x00FE, 0, 0x00FE, 0, 0x00FE]}
  end

  test "encodes and decodes file records from the specification" do
    read_request = {:read_file_record, [{4, 1, 2}, {3, 9, 2}]}

    assert PDU.encode_request(read_request) ==
             {:ok,
              <<0x14, 0x0E, 0x06, 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x06, 0x00, 0x03, 0x00,
                0x09, 0x00, 0x02>>}

    assert PDU.decode_response(
             read_request,
             <<0x14, 0x0C, 0x05, 0x06, 0x0D, 0xFE, 0x00, 0x20, 0x05, 0x06, 0x33, 0xCD, 0x00,
               0x40>>
           ) == {:ok, [[0x0DFE, 0x0020], [0x33CD, 0x0040]]}

    write_request = {:write_file_record, [{4, 7, [0x06AF, 0x04BE, 0x100D]}]}

    write_pdu =
      <<0x15, 0x0D, 0x06, 0x00, 0x04, 0x00, 0x07, 0x00, 0x03, 0x06, 0xAF, 0x04, 0xBE, 0x10, 0x0D>>

    assert PDU.encode_request(write_request) == {:ok, write_pdu}
    assert PDU.decode_response(write_request, write_pdu) == :ok
    assert PDU.broadcast_request?(write_request)
  end

  test "encodes and decodes device identification" do
    request = {:read_device_identification, :basic, 0}
    assert PDU.encode_request(request) == {:ok, <<0x2B, 0x0E, 0x01, 0x00>>}

    response =
      <<0x2B, 0x0E, 0x01, 0x01, 0x00, 0x00, 0x03, 0, 22, "Company identification", 1, 15,
        "Product code XX", 2, 5, "V2.11">>

    assert PDU.decode_response(request, response) ==
             {:ok,
              %{
                conformity_level: 1,
                more_follows: false,
                next_object_id: 0,
                objects: [
                  {0, "Company identification"},
                  {1, "Product code XX"},
                  {2, "V2.11"}
                ]
              }}
  end

  test "rejects invalid file records and device identification" do
    assert PDU.encode_request({:read_file_record, []}) == {:error, :invalid_quantity}

    assert PDU.encode_request({:read_file_record, [{0, 0, 1}]}) ==
             {:error, :invalid_file_record}

    assert PDU.encode_request({:read_file_record, [{1, 9_999, 2}]}) ==
             {:error, :invalid_file_record}

    assert PDU.encode_request({:write_file_record, [{1, 0, []}]}) ==
             {:error, :invalid_quantity}

    assert PDU.encode_request({:read_device_identification, :everything, 0}) ==
             {:error, :invalid_device_id_category}

    assert PDU.encode_request({:read_device_identification, :basic, 256}) ==
             {:error, :invalid_byte}

    invalid_file = <<0x14, 0x04, 0x03, 0x06, 0x00, 0x00>>

    assert PDU.decode_response({:read_file_record, [{1, 0, 2}]}, invalid_file) ==
             {:error, {:invalid_response, invalid_file}}

    invalid_id = <<0x2B, 0x0E, 0x01, 0x01, 0, 0, 2, 0, 1, ?A>>

    assert PDU.decode_response({:read_device_identification, :basic, 0}, invalid_id) ==
             {:error, {:invalid_response, invalid_id}}
  end

  test "encodes and decodes custom and encapsulated interface requests" do
    custom = {:custom, 100, <<1, 2, 3>>}
    assert PDU.encode_request(custom) == {:ok, <<100, 1, 2, 3>>}
    assert PDU.decode_response(custom, <<100, 9, 8>>) == {:ok, <<9, 8>>}
    assert PDU.broadcast_request?(custom)

    mei = {:encapsulated_interface_transport, 13, <<1, 2>>}
    assert PDU.encode_request(mei) == {:ok, <<0x2B, 13, 1, 2>>}
    assert PDU.decode_response(mei, <<0x2B, 13, 7, 8>>) == {:ok, <<7, 8>>}

    assert PDU.encode_request({:custom, 0, <<>>}) == {:error, :unsupported_request}

    assert PDU.encode_request({:encapsulated_interface_transport, 0x0E, <<>>}) ==
             {:error, :unsupported_request}

    assert PDU.response_length(custom, <<100, 1>>) == :unknown
    assert PDU.response_length(mei, <<0x2B, 13, 1>>) == :unknown
  end

  test "encodes and decodes serial status and diagnostics functions" do
    cases = [
      {:read_exception_status, <<0x07>>, <<0x07, 0x6D>>, {:ok, 0x6D}},
      {
        {:diagnostics, 0, [0xA537]},
        <<0x08, 0x00, 0x00, 0xA5, 0x37>>,
        <<0x08, 0x00, 0x00, 0xA5, 0x37>>,
        {:ok, [0xA537]}
      },
      {
        :get_comm_event_counter,
        <<0x0B>>,
        <<0x0B, 0xFF, 0xFF, 0x00, 0x03>>,
        {:ok, %{status: 0xFFFF, event_count: 3}}
      },
      {
        :get_comm_event_log,
        <<0x0C>>,
        <<0x0C, 0x08, 0x00, 0x00, 0x00, 0x03, 0x00, 0x05, 0x40, 0x20>>,
        {:ok, %{status: 0, event_count: 3, message_count: 5, events: [0x40, 0x20]}}
      },
      {
        :report_server_id,
        <<0x11>>,
        <<0x11, 0x03, 0x01, 0xFF, 0x00>>,
        {:ok, <<0x01, 0xFF, 0x00>>}
      },
      {
        {:read_fifo_queue, 0x04DE},
        <<0x18, 0x04, 0xDE>>,
        <<0x18, 0x00, 0x06, 0x00, 0x02, 0x00, 0x1F, 0x00, 0x20>>,
        {:ok, [31, 32]}
      }
    ]

    for {request, request_pdu, response_pdu, result} <- cases do
      assert PDU.encode_request(request) == {:ok, request_pdu}
      assert PDU.decode_response(request, response_pdu) == result
    end
  end

  test "validates bounded diagnostics and serial response shapes" do
    assert PDU.encode_request({:diagnostics, 1, []}) == {:error, :invalid_quantity}

    assert PDU.encode_request({:diagnostics, 1, [0, 1]}) ==
             {:error, :invalid_quantity}

    assert PDU.encode_request({:diagnostics, 0, [65_536]}) ==
             {:error, :invalid_register_value}

    assert PDU.encode_request({:diagnostics, 19, [0]}) ==
             {:error, :unsupported_diagnostics_sub_function}

    assert PDU.decode_response(:read_exception_status, <<0x07, 0x01>>) == {:ok, 0x01}

    assert PDU.decode_response(:read_exception_status, <<0x08, 0x01>>) ==
             {:error, {:invalid_response, <<0x08, 0x01>>}}

    assert PDU.decode_response(:get_comm_event_log, <<0x0C, 0x07, 0, 0, 0, 1, 0, 2, 0x40>>) ==
             {:ok, %{status: 0, event_count: 1, message_count: 2, events: [0x40]}}

    invalid_log = <<0x0C, 0x08, 0, 0, 0, 1, 0, 2, 0x40>>

    assert PDU.decode_response(:get_comm_event_log, invalid_log) ==
             {:error, {:invalid_response, invalid_log}}

    invalid_fifo = <<0x18, 0, 4, 0, 2, 0, 1>>

    assert PDU.decode_response({:read_fifo_queue, 0}, invalid_fifo) ==
             {:error, {:invalid_response, invalid_fifo}}
  end

  test "rejects values outside the application protocol limits" do
    assert PDU.encode_request({:read_coils, 0, 2_001}) == {:error, :invalid_quantity}
    assert PDU.encode_request({:read_holding_registers, 0, 126}) == {:error, :invalid_quantity}
    assert PDU.encode_request({:read_holding_registers, -1, 1}) == {:error, :invalid_address}

    assert PDU.encode_request({:read_holding_registers, 65_535, 2}) ==
             {:error, :invalid_address_range}

    assert PDU.encode_request({:write_single_register, 0, 65_536}) ==
             {:error, :invalid_register_value}

    assert PDU.encode_request({:write_multiple_coils, 0, []}) ==
             {:error, :invalid_quantity}

    assert PDU.encode_request({:write_multiple_coils, 0, [true, :maybe]}) ==
             {:error, :invalid_coil_value}

    assert PDU.encode_request({:write_multiple_registers, 0, [1, -1]}) ==
             {:error, :invalid_register_value}

    assert PDU.encode_request({:write_multiple_registers, 65_535, [1, 2]}) ==
             {:error, :invalid_address_range}

    assert PDU.encode_request({:mask_write_register, 0, 0x1_0000, 0}) ==
             {:error, :invalid_register_value}

    assert PDU.encode_request({:read_write_multiple_registers, 0, 126, 0, [1]}) ==
             {:error, :invalid_quantity}

    assert PDU.encode_request({:read_write_multiple_registers, 0, 1, 0, List.duplicate(1, 122)}) ==
             {:error, :invalid_quantity}

    assert PDU.encode_request({:read_write_multiple_registers, 0, 1, 0, [65_536]}) ==
             {:error, :invalid_register_value}

    assert PDU.encode_request({:read_write_multiple_registers, 65_535, 2, 0, [1]}) ==
             {:error, :invalid_address_range}

    assert PDU.encode_request({:read_write_multiple_registers, 0, 1, 65_535, [1, 2]}) ==
             {:error, :invalid_address_range}
  end

  test "requires a response to match its request" do
    short_read = <<0x03, 0x02, 0x00, 0x01>>

    assert PDU.decode_response({:read_holding_registers, 0, 2}, short_read) ==
             {:error, {:invalid_response, short_read}}

    wrong_echo = <<0x06, 0x00, 0x01, 0x00, 0x04>>

    assert PDU.decode_response({:write_single_register, 1, 3}, wrong_echo) ==
             {:error, {:invalid_response, wrong_echo}}

    wrong_function = <<0x02, 0x01, 0x01>>

    assert PDU.decode_response({:read_coils, 0, 1}, wrong_function) ==
             {:error, {:invalid_response, wrong_function}}
  end

  test "decodes exception responses" do
    assert PDU.decode_response({:read_holding_registers, 0, 1}, <<0x83, 0x02>>) ==
             {:error, {:exception, :illegal_data_address}}

    assert PDU.decode_response({:read_holding_registers, 0, 1}, <<0x83, 0x7F>>) ==
             {:error, {:exception, 0x7F}}

    assert PDU.decode_response(:read_exception_status, <<0x87, 0x02>>) ==
             {:error, {:exception, :illegal_data_address}}
  end

  test "derives response lengths from partial PDUs" do
    assert PDU.response_length({:read_holding_registers, 0, 2}, <<0x03>>) == :more
    assert PDU.response_length({:read_holding_registers, 0, 2}, <<0x03, 0x04>>) == {:ok, 6}
    assert PDU.response_length({:write_single_register, 1, 3}, <<0x06>>) == {:ok, 5}
    assert PDU.response_length({:read_holding_registers, 0, 2}, <<0x83>>) == :more
    assert PDU.response_length({:read_holding_registers, 0, 2}, <<0x83, 0x02>>) == {:ok, 2}
    assert PDU.response_length({:read_holding_registers, 0, 2}, <<0x04, 0x02>>) == :invalid

    assert PDU.response_length({:mask_write_register, 4, 0x00F2, 0x0025}, <<0x16>>) ==
             {:ok, 7}

    assert PDU.response_length(
             {:read_write_multiple_registers, 3, 6, 14, [0x00FF]},
             <<0x17, 0x0C>>
           ) == {:ok, 14}

    assert PDU.response_length(:read_exception_status, <<0x07>>) == {:ok, 2}
    assert PDU.response_length({:diagnostics, 0, [1, 2]}, <<0x08>>) == {:ok, 7}
    assert PDU.response_length({:diagnostics, 1, [0]}, <<0x08>>) == {:ok, 5}
    assert PDU.response_length(:get_comm_event_counter, <<0x0B>>) == {:ok, 5}
    assert PDU.response_length(:get_comm_event_log, <<0x0C, 0x08>>) == {:ok, 10}
    assert PDU.response_length(:report_server_id, <<0x11, 0x03>>) == {:ok, 5}
    assert PDU.response_length({:read_fifo_queue, 0}, <<0x18, 0x00, 0x06>>) == {:ok, 9}

    assert PDU.response_length({:read_file_record, [{1, 0, 1}]}, <<0x14, 0x04>>) ==
             {:ok, 6}

    assert PDU.response_length(
             {:read_device_identification, :basic, 0},
             <<0x2B, 0x0E, 0x01, 0x01, 0, 0, 1, 0, 3, "ABC">>
           ) == {:ok, 12}
  end

  test "classifies requests allowed on the broadcast unit" do
    assert PDU.broadcast_request?({:write_single_coil, 0, true})
    assert PDU.broadcast_request?({:write_single_register, 0, 1})
    assert PDU.broadcast_request?({:write_multiple_coils, 0, [true]})
    assert PDU.broadcast_request?({:write_multiple_registers, 0, [1]})
    assert PDU.broadcast_request?({:mask_write_register, 0, 0xFFFF, 0})

    refute PDU.broadcast_request?({:read_holding_registers, 0, 1})
    refute PDU.broadcast_request?({:read_write_multiple_registers, 0, 1, 0, [1]})
    refute PDU.broadcast_request?({:diagnostics, 0, []})
  end
end
