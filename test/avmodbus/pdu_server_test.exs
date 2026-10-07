defmodule AVModbus.PDUServerTest do
  use ExUnit.Case, async: true

  alias AVModbus.PDU

  test "decodes every supported data-model request" do
    requests = [
      {:read_coils, 19, 19},
      {:read_discrete_inputs, 196, 22},
      {:read_holding_registers, 107, 3},
      {:read_input_registers, 8, 1},
      {:write_single_coil, 172, true},
      {:write_single_register, 1, 3},
      :read_exception_status,
      {:diagnostics, 1, [0]},
      :get_comm_event_counter,
      :get_comm_event_log,
      {:write_multiple_coils, 19, [true, false, true, true, false, false, true, true]},
      {:write_multiple_registers, 1, [10, 258]},
      :report_server_id,
      {:read_file_record, [{4, 1, 2}, {3, 9, 2}]},
      {:write_file_record, [{4, 7, [0x06AF, 0x04BE, 0x100D]}]},
      {:mask_write_register, 4, 0x00F2, 0x0025},
      {:read_write_multiple_registers, 3, 6, 14, [0x00FF, 0x00FF, 0x00FF]},
      {:read_fifo_queue, 0x04DE},
      {:read_device_identification, :basic, 0},
      {:encapsulated_interface_transport, 13, <<1, 2>>},
      {:custom, 100, <<1, 2, 3>>}
    ]

    for request <- requests do
      assert {:ok, pdu} = PDU.encode_request(request)
      assert PDU.decode_request(pdu) == {:ok, request}
    end
  end

  test "classifies malformed request data as protocol exceptions" do
    assert PDU.decode_request(<<0x03, 0, 0, 0, 0>>) == {:error, :illegal_data_value}
    assert PDU.decode_request(<<0x05, 0, 1, 0x12, 0x34>>) == {:error, :illegal_data_value}
    assert PDU.decode_request(<<0x0F, 0, 0, 0, 9, 1, 0xFF>>) == {:error, :illegal_data_value}
    assert PDU.decode_request(<<0x2B, 0x0E, 5, 0>>) == {:error, :illegal_data_value}

    assert PDU.decode_request(<<0x14, 7, 5, 0, 1, 0, 0, 0, 1>>) ==
             {:error, :illegal_data_address}

    assert PDU.decode_request(<<0x14, 7, 6, 0, 1, 0x27, 0x0F, 0, 2>>) ==
             {:error, :illegal_data_address}

    assert PDU.decode_request(<<0x08, 0, 19, 0, 1, 0, 2>>) ==
             {:ok, {:diagnostics, 19, [1, 2]}}

    assert PDU.decode_request(<<0x00>>) == {:error, :illegal_function}
    assert PDU.decode_request(<<0x64, 1, 2>>) == {:ok, {:custom, 0x64, <<1, 2>>}}
  end

  test "encodes responses and validates handler result shapes" do
    cases = [
      {{:read_coils, 0, 9}, {:ok, [true, false, true, false, true, false, true, false, true]},
       <<0x01, 2, 0x55, 0x01>>},
      {{:read_holding_registers, 0, 2}, {:ok, [0x1234, 0xABCD]},
       <<0x03, 4, 0x12, 0x34, 0xAB, 0xCD>>},
      {{:read_discrete_inputs, 0, 3}, {:ok, [true, false, true]}, <<0x02, 1, 0x05>>},
      {{:read_input_registers, 0, 1}, {:ok, [42]}, <<0x04, 2, 0, 42>>},
      {{:write_single_coil, 3, true}, :ok, <<0x05, 0, 3, 0xFF, 0>>},
      {{:write_single_register, 1, 3}, :ok, <<0x06, 0, 1, 0, 3>>},
      {:read_exception_status, {:ok, 0x6D}, <<0x07, 0x6D>>},
      {{:diagnostics, 0, [0xA537]}, {:ok, [0xA537]}, <<0x08, 0, 0, 0xA5, 0x37>>},
      {:get_comm_event_counter, {:ok, %{status: 0xFFFF, event_count: 3}},
       <<0x0B, 0xFF, 0xFF, 0, 3>>},
      {:get_comm_event_log,
       {:ok, %{status: 0, event_count: 3, message_count: 5, events: [0x40, 0x20]}},
       <<0x0C, 8, 0, 0, 0, 3, 0, 5, 0x40, 0x20>>},
      {{:write_multiple_coils, 2, [true, false]}, :ok, <<0x0F, 0, 2, 0, 2>>},
      {{:write_multiple_registers, 2, [1, 2]}, :ok, <<0x10, 0, 2, 0, 2>>},
      {:report_server_id, {:ok, <<1, 0xFF, 0>>}, <<0x11, 3, 1, 0xFF, 0>>},
      {{:read_file_record, [{4, 1, 2}]}, {:ok, [[0x0DFE, 0x0020]]},
       <<0x14, 6, 5, 6, 0x0D, 0xFE, 0, 0x20>>},
      {{:write_file_record, [{4, 7, [0x06AF]}]}, :ok, <<0x15, 9, 6, 0, 4, 0, 7, 0, 1, 6, 0xAF>>},
      {{:mask_write_register, 4, 0x00F2, 0x0025}, :ok, <<0x16, 0, 4, 0, 0xF2, 0, 0x25>>},
      {{:read_write_multiple_registers, 3, 2, 14, [0x00FF]}, {:ok, [1, 2]},
       <<0x17, 4, 0, 1, 0, 2>>},
      {{:read_fifo_queue, 10}, {:ok, [31, 32]}, <<0x18, 0, 6, 0, 2, 0, 31, 0, 32>>},
      {{:encapsulated_interface_transport, 13, <<1>>}, {:ok, <<9, 8>>}, <<0x2B, 13, 9, 8>>},
      {{:custom, 100, <<1>>}, {:ok, <<9, 8>>}, <<100, 9, 8>>}
    ]

    for {request, result, response} <- cases do
      assert PDU.encode_response(request, result) == {:ok, response}
      assert PDU.decode_response(request, response) == normalize_client_result(result)
    end

    assert PDU.encode_response({:read_holding_registers, 0, 2}, {:ok, [1]}) ==
             {:error, :invalid_handler_result}

    assert PDU.encode_response({:read_coils, 0, 1}, {:ok, [1]}) ==
             {:error, :invalid_handler_result}
  end

  test "encodes exception and device-identification responses" do
    assert PDU.encode_response(
             {:read_holding_registers, 0, 1},
             {:error, {:exception, :illegal_data_address}}
           ) == {:ok, <<0x83, 0x02>>}

    request = {:read_device_identification, :basic, 0}

    result =
      {:ok,
       %{
         conformity_level: 0x81,
         more_follows: false,
         next_object_id: 0,
         objects: [{0, "Acme"}, {1, "A1"}, {2, "1.0"}]
       }}

    assert {:ok, response} = PDU.encode_response(request, result)
    assert PDU.decode_response(request, response) == result
  end

  test "derives request lengths from partial PDUs" do
    assert PDU.request_length(<<>>) == :more
    assert PDU.request_length(<<0x03>>) == {:ok, 5}
    assert PDU.request_length(<<0x0F, 0, 0, 0, 9>>) == :more
    assert PDU.request_length(<<0x0F, 0, 0, 0, 9, 2>>) == {:ok, 8}
    assert PDU.request_length(<<0x17, 0, 0, 0, 1, 0, 2, 0, 1, 2>>) == {:ok, 12}
    assert PDU.request_length(<<0x2B, 0x0E>>) == {:ok, 4}
    assert PDU.request_length(<<100, 1>>) == :unknown
    assert PDU.request_length(<<0>>) == :invalid
  end

  defp normalize_client_result(:ok), do: :ok
  defp normalize_client_result({:ok, value}), do: {:ok, value}
end
