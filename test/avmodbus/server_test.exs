defmodule AVModbus.ServerTest do
  use ExUnit.Case, async: true

  alias AVModbus.{PDU, Server}

  defmodule EchoHandler do
    @behaviour AVModbus.Server

    @impl AVModbus.Server
    def handle_request(unit_id, {:read_holding_registers, _address, 2}, argument),
      do: {:ok, [unit_id, argument]}
  end

  test "serves a function handler through request and response codecs" do
    handler = fn
      _unit_id, {:read_input_registers, 0, 2} -> {:ok, [215, 1013]}
      _unit_id, _request -> {:error, {:exception, :illegal_function}}
    end

    request = {:read_input_registers, 0, 2}
    {:ok, request_pdu} = PDU.encode_request(request)

    assert {:ok, response_pdu} = Server.respond(handler, 1, request_pdu)
    assert PDU.decode_response(request, response_pdu) == {:ok, [215, 1013]}

    {:ok, rejected_pdu} = PDU.encode_request({:read_coils, 0, 1})
    assert Server.respond(handler, 1, rejected_pdu) == {:ok, <<0x81, 0x01>>}
  end

  test "serves a module handler with its argument" do
    request = {:read_holding_registers, 0, 2}
    {:ok, request_pdu} = PDU.encode_request(request)

    assert {:ok, response_pdu} = Server.respond({EchoHandler, 42}, 9, request_pdu)
    assert PDU.decode_response(request, response_pdu) == {:ok, [9, 42]}
  end

  test "turns malformed requests and bad handlers into exceptions" do
    handler = fn _unit_id, _request -> :ok end

    assert Server.respond(handler, 1, <<0x03, 0, 0, 0, 0>>) == {:ok, <<0x83, 0x03>>}
    assert Server.respond(handler, 1, <<>>) == :ignore
    assert Server.respond(handler, 1, <<0x80>>) == {:ok, <<0x80, 0x01>>}

    request = {:read_holding_registers, 0, 2}
    {:ok, request_pdu} = PDU.encode_request(request)

    assert Server.respond(handler, 1, request_pdu) == {:ok, <<0x83, 0x04>>}

    raising = fn _unit_id, _request -> raise "failed" end
    assert Server.respond(raising, 1, request_pdu) == {:ok, <<0x83, 0x04>>}
  end

  test "maps gateway and client exception errors" do
    request = {:read_coils, 0, 1}
    {:ok, request_pdu} = PDU.encode_request(request)

    assert Server.handle_request(fn _, _ -> {:error, :timeout} end, 1, request) ==
             {:error, {:exception, :gateway_target_device_failed_to_respond}}

    assert Server.handle_request(fn _, _ -> {:error, :closed} end, 1, request) ==
             {:error, {:exception, :gateway_path_unavailable}}

    assert Server.handle_request(
             fn _, _ -> {:error, {:exception, :illegal_data_address}} end,
             1,
             request
           ) == {:error, {:exception, :illegal_data_address}}

    gateway = fn _unit_id, downstream_request ->
      PDU.decode_response(downstream_request, <<0x81, 0x02>>)
    end

    assert Server.respond(gateway, 1, request_pdu) == {:ok, <<0x81, 0x02>>}
  end

  test "isolates and kills a handler that exceeds its timeout" do
    test_process = self()

    handler = fn
      _unit_id, {:read_holding_registers, 0, 1} ->
        send(test_process, {:handler_started, self()})

        receive do
          :never -> {:ok, [0]}
        end

      _unit_id, {:read_holding_registers, 1, 1} ->
        {:ok, [42]}
    end

    {:ok, blocked_pdu} = PDU.encode_request({:read_holding_registers, 0, 1})

    assert Server.respond(handler, 1, blocked_pdu, 20) == {:ok, <<0x83, 0x04>>}
    assert_received {:handler_started, handler_pid}
    refute Process.alive?(handler_pid)

    {:ok, next_pdu} = PDU.encode_request({:read_holding_registers, 1, 1})
    assert {:ok, response_pdu} = Server.respond(handler, 1, next_pdu, 20)
    assert PDU.decode_response({:read_holding_registers, 1, 1}, response_pdu) == {:ok, [42]}
  end

  test "authorizes requests and serves identification before the handler" do
    test_process = self()

    handler = fn _unit_id, request ->
      send(test_process, {:handled, request})
      {:ok, [42]}
    end

    authorize = fn role, unit_id, request ->
      send(test_process, {:authorized, role, unit_id, request})
      not match?({:write_single_register, _, _}, request)
    end

    identification = %{0 => "AVModbus", 1 => "device", 2 => "0.1.0"}
    policy = %{authorize: authorize, identification: identification, role: :serial}

    id_request = {:read_device_identification, :basic, 0}
    {:ok, id_pdu} = PDU.encode_request(id_request)
    assert {:ok, id_response} = Server.respond(handler, 7, id_pdu, 100, policy)

    assert {:ok,
            %{
              objects: [{0, "AVModbus"}, {1, "device"}, {2, "0.1.0"}],
              conformity_level: 0x81
            }} = PDU.decode_response(id_request, id_response)

    assert_received {:authorized, :serial, 7, ^id_request}
    refute_received {:handled, ^id_request}

    denied = {:write_single_register, 0, 9}
    {:ok, denied_pdu} = PDU.encode_request(denied)
    assert Server.respond(handler, 7, denied_pdu, 100, policy) == {:ok, <<0x86, 0x01>>}
    refute_received {:handled, ^denied}
  end

  test "authorization crashes and timeouts deny transport-owned requests" do
    request = {:diagnostics, 0, [1]}
    assert Server.allowed?(fn _, _, _ -> raise "no" end, nil, 1, request, 100) == false

    blocked = fn _, _, _ ->
      receive do
        :never -> true
      end
    end

    assert Server.allowed?(blocked, nil, 1, request, 10) == false
  end
end
