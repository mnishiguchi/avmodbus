defmodule AVModbus.RTUServerTest do
  use ExUnit.Case, async: true

  alias AVModbus.{Memory, PDU, RTU}
  alias AVModbus.Server.RTU, as: RTUServer

  defmodule FakeTransport do
    def start_link(options \\ []) do
      owner = self()

      Agent.start_link(fn ->
        %{chunks: [], writes: [], owner: owner, echo_writes: options[:echo_writes] == true}
      end)
    end

    def push(agent, data) do
      Agent.update(agent, fn state -> %{state | chunks: state.chunks ++ [data]} end)
    end

    def read(agent, timeout_ms) do
      chunk =
        Agent.get_and_update(agent, fn
          %{chunks: [chunk | rest]} = state -> {chunk, %{state | chunks: rest}}
          state -> {nil, state}
        end)

      if is_binary(chunk) do
        {:ok, chunk}
      else
        Process.sleep(timeout_ms)
        {:error, :timeout}
      end
    end

    def write(agent, data) do
      Agent.update(agent, fn state ->
        send(state.owner, {:transport_write, data})
        chunks = if state.echo_writes, do: state.chunks ++ [data], else: state.chunks
        %{state | writes: state.writes ++ [data], chunks: chunks}
      end)
    end

    def writes(agent), do: Agent.get(agent, & &1.writes)
    def close(_agent), do: :ok
  end

  defmodule ReopeningTransport do
    def start_link(open_results) do
      owner = self()

      Agent.start_link(
        fn ->
          %{
            open_results: open_results,
            open_count: 0,
            reads: [],
            writes: [],
            closes: 0,
            owner: owner
          }
        end,
        name: __MODULE__
      )
    end

    def open do
      Agent.get_and_update(__MODULE__, fn
        %{open_results: [result | rest]} = state ->
          {result, %{state | open_results: rest, open_count: state.open_count + 1}}

        state ->
          {{:ok, :reopened_uart}, %{state | open_count: state.open_count + 1}}
      end)
    end

    def read(_uart, timeout_ms) do
      result =
        Agent.get_and_update(__MODULE__, fn
          %{reads: [result | rest]} = state -> {result, %{state | reads: rest}}
          state -> {nil, state}
        end)

      if is_nil(result) do
        Process.sleep(timeout_ms)
        {:error, :timeout}
      else
        result
      end
    end

    def write(_uart, data) do
      Agent.update(__MODULE__, fn state ->
        send(state.owner, {:reopening_transport_write, data})
        %{state | writes: state.writes ++ [data]}
      end)
    end

    def close(_uart) do
      Agent.update(__MODULE__, fn state -> %{state | closes: state.closes + 1} end)
    end

    def push(result) do
      Agent.update(__MODULE__, fn state -> %{state | reads: state.reads ++ [result]} end)
    end

    def open_count, do: Agent.get(__MODULE__, & &1.open_count)
    def close_count, do: Agent.get(__MODULE__, & &1.closes)
  end

  test "reassembles a noisy fragmented request and replies" do
    memory = start_supervised!({Memory, holding_registers: 10})
    :ok = Memory.put(memory, :holding_register, 2, [42])
    {transport, server} = start_server({Memory, memory})

    request = {:read_holding_registers, 2, 1}
    {:ok, pdu} = PDU.encode_request(request)
    {:ok, frame} = RTU.encode(3, pdu)
    <<head::binary-size(3), tail::binary>> = frame

    FakeTransport.push(transport, <<0xFF, head::binary>>)
    FakeTransport.push(transport, tail)

    assert_receive {:transport_write, response}, 500
    assert {:ok, 3, response_pdu} = RTU.decode(response)
    assert PDU.decode_response(request, response_pdu) == {:ok, [42]}
    stop_server(server, transport)
  end

  test "ignores other units and applies broadcast writes without replying" do
    memory = start_supervised!({Memory, holding_registers: 10})
    {transport, server} = start_server({Memory, memory})

    {:ok, other_pdu} = PDU.encode_request({:read_holding_registers, 1, 1})
    {:ok, other_frame} = RTU.encode(9, other_pdu)
    {:ok, write_pdu} = PDU.encode_request({:write_single_register, 1, 77})
    {:ok, broadcast_frame} = RTU.encode(0, write_pdu)
    request = {:read_holding_registers, 1, 1}
    {:ok, read_pdu} = PDU.encode_request(request)
    {:ok, read_frame} = RTU.encode(3, read_pdu)

    FakeTransport.push(transport, other_frame <> broadcast_frame <> read_frame)

    assert_receive {:transport_write, response}, 500
    assert {:ok, 3, response_pdu} = RTU.decode(response)
    assert PDU.decode_response(request, response_pdu) == {:ok, [77]}
    refute_receive {:transport_write, _another}, 30
    assert FakeTransport.writes(transport) == [response]
    stop_server(server, transport)
  end

  test "answers malformed addressed requests with a Modbus exception" do
    handler = fn _unit_id, _request -> {:ok, [0]} end
    {transport, server} = start_server(handler)
    {:ok, frame} = RTU.encode(3, <<0x03, 0, 0, 0, 0>>)

    FakeTransport.push(transport, frame)

    assert_receive {:transport_write, response}, 500
    assert RTU.decode(response) == {:ok, 3, <<0x83, 0x03>>}
    stop_server(server, transport)
  end

  test "recovers from a bad CRC before a valid request" do
    memory = start_supervised!({Memory, holding_registers: 10})
    :ok = Memory.put(memory, :holding_register, 0, [42])
    {transport, server} = start_server({Memory, memory})
    request = {:read_holding_registers, 0, 1}
    {:ok, pdu} = PDU.encode_request(request)
    {:ok, frame} = RTU.encode(3, pdu)
    prefix_size = byte_size(frame) - 1
    <<prefix::binary-size(prefix_size), last>> = frame
    bad_frame = <<prefix::binary, Bitwise.bxor(last, 1)>>

    FakeTransport.push(transport, bad_frame <> frame)

    assert_receive {:transport_write, response}, 500
    assert {:ok, 3, response_pdu} = RTU.decode(response)
    assert PDU.decode_response(request, response_pdu) == {:ok, [42]}
    stop_server(server, transport)
  end

  test "ignores broadcast reads" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    handler = fn _unit_id, _request ->
      Agent.update(calls, &(&1 + 1))
      {:ok, [0]}
    end

    {transport, server} = start_server(handler)
    {:ok, pdu} = PDU.encode_request({:read_holding_registers, 0, 1})
    {:ok, frame} = RTU.encode(0, pdu)
    FakeTransport.push(transport, frame)

    Process.sleep(30)
    assert Agent.get(calls, & &1) == 0
    assert FakeTransport.writes(transport) == []
    stop_server(server, transport)
    Agent.stop(calls)
  end

  test "uses silence to delimit a custom request" do
    handler = fn 3, {:custom, 100, <<1, 2>>} -> {:ok, <<9, 8>>} end
    {transport, server} = start_server(handler)
    {:ok, frame} = RTU.encode(3, <<100, 1, 2>>)

    FakeTransport.push(transport, frame)

    assert_receive {:transport_write, response}, 500
    assert RTU.decode(response) == {:ok, 3, <<100, 9, 8>>}
    stop_server(server, transport)
  end

  test "suppresses an adapter echo of its response" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    handler = fn _unit_id, {:read_holding_registers, 0, 1} ->
      Agent.update(calls, &(&1 + 1))
      {:ok, [42]}
    end

    {transport, server} = start_server(handler, [echo_writes: true], echo: true)
    {:ok, pdu} = PDU.encode_request({:read_holding_registers, 0, 1})
    {:ok, frame} = RTU.encode(3, pdu)
    FakeTransport.push(transport, frame)

    assert_receive {:transport_write, _response}, 500
    Process.sleep(30)
    assert Agent.get(calls, & &1) == 1
    assert length(FakeTransport.writes(transport)) == 1
    stop_server(server, transport)
    Agent.stop(calls)
  end

  test "owns the serial diagnostic counters" do
    memory = start_supervised!({Memory, holding_registers: 10})
    {transport, server} = start_server({Memory, memory})

    assert exchange(transport, 3, {:diagnostics, 0, [0xA537, 1]}) ==
             {:ok, [0xA537, 1]}

    assert exchange(transport, 3, {:read_holding_registers, 9, 2}) ==
             {:error, {:exception, :illegal_data_address}}

    send_without_response(transport, 9, {:read_holding_registers, 0, 1})

    assert exchange(transport, 3, {:diagnostics, 0x0B, [0]}) == {:ok, [4]}
    assert exchange(transport, 3, {:diagnostics, 0x0E, [0]}) == {:ok, [4]}
    assert exchange(transport, 3, {:diagnostics, 0x0D, [0]}) == {:ok, [1]}

    {:ok, request_pdu} = PDU.encode_request({:read_holding_registers, 0, 1})
    {:ok, frame} = RTU.encode(3, request_pdu)
    prefix_size = byte_size(frame) - 1
    <<prefix::binary-size(prefix_size), last>> = frame
    FakeTransport.push(transport, <<prefix::binary, Bitwise.bxor(last, 1)>>)
    Process.sleep(20)
    assert exchange(transport, 3, {:diagnostics, 0x0C, [0]}) == {:ok, [1]}

    FakeTransport.push(transport, <<3, 100, 0::size(255)-unit(8)>>)
    Process.sleep(20)
    assert exchange(transport, 3, {:diagnostics, 0x12, [0]}) == {:ok, [1]}
    assert exchange(transport, 3, {:diagnostics, 20, [0]}) == {:ok, [0]}
    assert exchange(transport, 3, {:diagnostics, 0x12, [0]}) == {:ok, [0]}
    assert exchange(transport, 3, {:diagnostics, 2, [0]}) == {:ok, [0]}

    assert exchange(transport, 3, {:diagnostics, 0x0B, [1]}) ==
             {:error, {:exception, :illegal_data_value}}

    assert exchange_pdu(transport, 3, <<0x08, 0x00, 0x63, 0x00, 0x00>>) == <<0x88, 0x01>>

    assert exchange(transport, 3, {:diagnostics, 10, [0]}) == {:ok, [0]}
    assert exchange(transport, 3, {:diagnostics, 0x0D, [0]}) == {:ok, [0]}
    stop_server(server, transport)
  end

  test "counts broadcasts, busy responses, and negative acknowledgements" do
    handler = fn
      _unit_id, {:write_single_register, 0, _value} ->
        {:error, {:exception, :server_device_busy}}

      _unit_id, {:write_single_register, 1, _value} ->
        {:error, {:exception, 7}}

      _unit_id, {:write_single_register, _address, _value} ->
        :ok
    end

    {transport, server} = start_server(handler)
    send_without_response(transport, 0, {:write_single_register, 2, 42})
    assert exchange(transport, 3, {:diagnostics, 0x0F, [0]}) == {:ok, [1]}

    assert exchange(transport, 3, {:write_single_register, 0, 42}) ==
             {:error, {:exception, :server_device_busy}}

    assert exchange(transport, 3, {:write_single_register, 1, 42}) ==
             {:error, {:exception, 7}}

    assert exchange(transport, 3, {:diagnostics, 0x11, [0]}) == {:ok, [1]}
    assert exchange(transport, 3, {:diagnostics, 0x10, [0]}) == {:ok, [1]}
    stop_server(server, transport)
  end

  test "reports the communication event counter and newest-first event log" do
    memory = start_supervised!({Memory, holding_registers: 10})
    {transport, server} = start_server({Memory, memory})

    assert exchange(transport, 3, {:read_holding_registers, 0, 1}) == {:ok, [0]}
    assert exchange(transport, 3, {:read_holding_registers, 0, 1}) == {:ok, [0]}

    assert exchange(transport, 3, {:read_holding_registers, 9, 2}) ==
             {:error, {:exception, :illegal_data_address}}

    assert exchange(transport, 3, :get_comm_event_counter) ==
             {:ok, %{status: 0, event_count: 2}}

    assert {:ok, log} = exchange(transport, 3, :get_comm_event_log)
    assert %{status: 0, event_count: 2, message_count: 5} = log
    assert log.events == [0x80, 0x40, 0x80, 0x41, 0x80, 0x40, 0x80, 0x40, 0x80]
    stop_server(server, transport)
  end

  test "enters listen-only mode until restart communications" do
    memory = start_supervised!({Memory, holding_registers: 10})
    {transport, server} = start_server({Memory, memory})

    send_without_response(transport, 3, {:diagnostics, 4, [0]})
    send_without_response(transport, 3, {:read_holding_registers, 0, 1})
    send_without_response(transport, 3, {:diagnostics, 1, [0]})
    assert exchange(transport, 3, {:read_holding_registers, 0, 1}) == {:ok, [0]}

    assert {:ok, %{events: events}} = exchange(transport, 3, :get_comm_event_log)
    assert events == [0x80, 0x40, 0x80, 0x00, 0xA0, 0xA0, 0x04, 0x80]
    stop_server(server, transport)
  end

  test "continues serving after an isolated handler timeout" do
    handler = fn
      _unit_id, {:read_holding_registers, 0, 1} ->
        receive do
          :never -> {:ok, [0]}
        end

      _unit_id, {:read_holding_registers, 1, 1} ->
        {:ok, [42]}
    end

    {transport, server} = start_server(handler, [], handler_timeout: 20)

    assert exchange(transport, 3, {:read_holding_registers, 0, 1}) ==
             {:error, {:exception, :server_device_failure}}

    assert exchange(transport, 3, {:read_holding_registers, 1, 1}) == {:ok, [42]}
    stop_server(server, transport)
  end

  test "serves built-in device identification" do
    handler = fn _unit_id, _request -> flunk("identification reached the handler") end
    identification = %{0 => "AVModbus", 1 => "XIAO ESP32-C5", 2 => "0.1.0"}
    {transport, server} = start_server(handler, [], identification: identification)

    assert {:ok,
            %{
              objects: [{0, "AVModbus"}, {1, "XIAO ESP32-C5"}, {2, "0.1.0"}],
              conformity_level: 0x81
            }} = exchange(transport, 3, {:read_device_identification, :basic, 0})

    assert exchange(transport, 3, {:read_device_identification, :individual, 9}) ==
             {:error, {:exception, :illegal_data_address}}

    stop_server(server, transport)
  end

  test "authorizes handler, broadcast, and RTU-owned requests" do
    memory = start_supervised!({Memory, holding_registers: 10})
    test_process = self()

    authorize = fn role, unit_id, request ->
      send(test_process, {:authorized, role, unit_id, request})

      not match?({:diagnostics, _, _}, request) and request != :get_comm_event_log and
        not match?({:write_single_register, _, _}, request)
    end

    {transport, server} = start_server({Memory, memory}, [], authorize: authorize)

    assert exchange(transport, 3, {:read_holding_registers, 0, 1}) == {:ok, [0]}

    assert exchange(transport, 3, {:diagnostics, 0, [42]}) ==
             {:error, {:exception, :illegal_function}}

    assert exchange(transport, 3, :get_comm_event_log) ==
             {:error, {:exception, :illegal_function}}

    assert {:ok, %{event_count: _count}} = exchange(transport, 3, :get_comm_event_counter)

    send_without_response(transport, 0, {:write_single_register, 0, 99})
    assert Memory.get(memory, :holding_register, 0, 1) == [0]

    assert_received {:authorized, nil, 3, {:read_holding_registers, 0, 1}}
    assert_received {:authorized, nil, 0, {:write_single_register, 0, 99}}
    stop_server(server, transport)
  end

  test "starts disconnected and reopens the UART with backoff" do
    {:ok, transport_state} =
      ReopeningTransport.start_link([{:error, :device_missing}, {:ok, :reopened_uart}])

    memory = start_supervised!({Memory, holding_registers: 10})

    {:ok, server} =
      RTUServer.start_link(
        ReopeningTransport,
        {Memory, memory},
        units: [3],
        silence: 5,
        gap: 0,
        backoff: {50, 50}
      )

    assert RTUServer.status(server) == {:disconnected, :device_missing}
    assert wait_until(fn -> RTUServer.status(server) == :connected end)

    {:ok, request_pdu} = PDU.encode_request({:read_holding_registers, 0, 1})
    {:ok, request_frame} = RTU.encode(3, request_pdu)
    ReopeningTransport.push({:ok, request_frame})

    assert_receive {:reopening_transport_write, response_frame}, 500
    assert {:ok, 3, response_pdu} = RTU.decode(response_frame)
    assert PDU.decode_response({:read_holding_registers, 0, 1}, response_pdu) == {:ok, [0]}
    assert ReopeningTransport.open_count() == 2

    RTUServer.close(server)
    assert ReopeningTransport.close_count() == 1
    Agent.stop(transport_state)
  end

  test "reopens after a connected UART read error" do
    {:ok, transport_state} =
      ReopeningTransport.start_link([{:ok, :first_uart}, {:ok, :second_uart}])

    memory = start_supervised!({Memory, holding_registers: 10})

    {:ok, server} =
      RTUServer.start_link(
        ReopeningTransport,
        {Memory, memory},
        units: [3],
        silence: 5,
        gap: 0,
        backoff: {5, 10}
      )

    ReopeningTransport.push({:error, :uart_failed})
    assert wait_until(fn -> ReopeningTransport.open_count() == 2 end)
    assert RTUServer.status(server) == :connected
    assert ReopeningTransport.close_count() == 1

    {:ok, request_pdu} = PDU.encode_request({:read_holding_registers, 0, 1})
    {:ok, request_frame} = RTU.encode(3, request_pdu)
    ReopeningTransport.push({:ok, request_frame})
    assert_receive {:reopening_transport_write, _response_frame}, 500

    RTUServer.close(server)
    assert ReopeningTransport.close_count() == 2
    Agent.stop(transport_state)
  end

  test "validates RTU server options" do
    {:ok, transport} = FakeTransport.start_link()
    handler = fn _unit_id, _request -> :ok end

    assert RTUServer.start_link(FakeTransport, transport, handler, []) ==
             {:error, :invalid_units_option}

    assert RTUServer.start_link(FakeTransport, transport, handler, units: [0]) ==
             {:error, :invalid_units_option}

    assert RTUServer.start_link(FakeTransport, transport, handler, units: [1], gap: -1) ==
             {:error, :invalid_gap_option}

    assert RTUServer.start_link(FakeTransport, transport, handler, units: [1], echo: :yes) ==
             {:error, :invalid_echo_option}

    assert RTUServer.start_link(
             FakeTransport,
             transport,
             handler,
             units: [1],
             handler_timeout: 0
           ) == {:error, :invalid_handler_timeout_option}

    assert RTUServer.start_link(
             FakeTransport,
             transport,
             handler,
             units: [1],
             backoff: {10, 5}
           ) == {:error, :invalid_backoff_option}

    assert RTUServer.start_link(
             FakeTransport,
             transport,
             handler,
             units: [1],
             authorize: :yes
           ) == {:error, :invalid_authorize_option}

    assert RTUServer.start_link(
             FakeTransport,
             transport,
             handler,
             units: [1],
             identification: %{0 => "vendor"}
           ) == {:error, {:missing_identification_objects, [1, 2]}}

    Agent.stop(transport)
  end

  defp start_server(handler, transport_options \\ [], server_options \\ []) do
    {:ok, transport} = FakeTransport.start_link(transport_options)

    {:ok, server} =
      RTUServer.start_link(
        FakeTransport,
        transport,
        handler,
        [units: [3], silence: 5, gap: 0] ++ server_options
      )

    {transport, server}
  end

  defp stop_server(server, transport) do
    RTUServer.close(server)
    Agent.stop(transport)
  end

  defp exchange(transport, unit_id, request) do
    {:ok, request_pdu} = PDU.encode_request(request)
    {:ok, request_frame} = RTU.encode(unit_id, request_pdu)
    FakeTransport.push(transport, request_frame)

    assert_receive {:transport_write, response_frame}, 500
    assert {:ok, ^unit_id, response_pdu} = RTU.decode(response_frame)
    PDU.decode_response(request, response_pdu)
  end

  defp send_without_response(transport, unit_id, request) do
    {:ok, request_pdu} = PDU.encode_request(request)
    {:ok, request_frame} = RTU.encode(unit_id, request_pdu)
    FakeTransport.push(transport, request_frame)
    refute_receive {:transport_write, _response}, 30
  end

  defp exchange_pdu(transport, unit_id, request_pdu) do
    {:ok, request_frame} = RTU.encode(unit_id, request_pdu)
    FakeTransport.push(transport, request_frame)

    assert_receive {:transport_write, response_frame}, 500
    assert {:ok, ^unit_id, response_pdu} = RTU.decode(response_frame)
    response_pdu
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end
end
