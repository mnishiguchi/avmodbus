defmodule AVModbus.ClientTest do
  use ExUnit.Case, async: true

  alias AVModbus.{ASCII, Client, RTU}

  defmodule FakeTransport do
    def start_link(chunks) do
      Agent.start_link(fn -> %{chunks: chunks, writes: [], reads: 0} end)
    end

    def write(agent, data) do
      Agent.update(agent, fn state -> %{state | writes: [data | state.writes]} end)
    end

    def read(agent, _timeout_ms) do
      Agent.get_and_update(agent, fn
        %{chunks: [chunk | rest]} = state ->
          {{:ok, chunk}, %{state | chunks: rest, reads: state.reads + 1}}

        state ->
          {{:error, :timeout}, %{state | reads: state.reads + 1}}
      end)
    end

    def writes(agent) do
      Agent.get(agent, fn state -> Enum.reverse(state.writes) end)
    end

    def read_count(agent), do: Agent.get(agent, & &1.reads)
  end

  defmodule DelayedTransport do
    def start_link(chunks) do
      Agent.start_link(fn -> chunks end)
    end

    def write(_agent, _data), do: :ok

    def read(agent, timeout_ms) do
      {delay_ms, result} =
        Agent.get_and_update(agent, fn
          [{delay_ms, chunk} | rest] when delay_ms <= timeout_ms ->
            {{delay_ms, {:ok, chunk}}, rest}

          [{_delay_ms, _chunk} | _rest] = chunks ->
            {{timeout_ms, {:error, :timeout}}, chunks}

          [] ->
            {{0, {:error, :timeout}}, []}
        end)

      Process.sleep(delay_ms)
      result
    end
  end

  defmodule ConcurrentTransport do
    def start_link(response) do
      owner = self()

      Agent.start_link(fn ->
        %{response: response, active: 0, max_active: 0, writes: 0, owner: owner}
      end)
    end

    def write(agent, _data) do
      Agent.update(agent, fn state ->
        send(state.owner, :transport_write)
        active = state.active + 1

        %{
          state
          | active: active,
            max_active: max(active, state.max_active),
            writes: state.writes + 1
        }
      end)
    end

    def read(agent, _timeout_ms) do
      Process.sleep(10)

      Agent.get_and_update(agent, fn state ->
        {{:ok, state.response}, %{state | active: state.active - 1}}
      end)
    end

    def max_active(agent), do: Agent.get(agent, & &1.max_active)
    def write_count(agent), do: Agent.get(agent, & &1.writes)
  end

  defmodule BlockingTransport do
    def start_link(response) do
      owner = self()
      Agent.start_link(fn -> %{response: response, writes: 0, owner: owner} end)
    end

    def write(agent, _data) do
      Agent.update(agent, fn state ->
        send(state.owner, :transport_write)
        %{state | writes: state.writes + 1}
      end)
    end

    def read(agent, _timeout_ms) do
      %{owner: owner, response: response} = Agent.get(agent, & &1)
      send(owner, {:transport_read, self()})

      receive do
        :release_read -> {:ok, response}
      end
    end

    def write_count(agent), do: Agent.get(agent, & &1.writes)
  end

  defmodule ReopeningTransport do
    def start_link(open_results) do
      Agent.start_link(
        fn ->
          %{
            open_results: open_results,
            open_count: 0,
            reads: [],
            writes: [],
            closes: 0
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

    def write(_uart, data) do
      Agent.update(__MODULE__, fn state -> %{state | writes: state.writes ++ [data]} end)
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

    def close(_uart) do
      Agent.update(__MODULE__, fn state -> %{state | closes: state.closes + 1} end)
    end

    def push(result) do
      Agent.update(__MODULE__, fn state -> %{state | reads: state.reads ++ [result]} end)
    end

    def open_count, do: Agent.get(__MODULE__, & &1.open_count)
    def close_count, do: Agent.get(__MODULE__, & &1.closes)
  end

  test "performs a transaction across partial reads and leading noise" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x04, 0x00, 0x0A, 0x01, 0x02>>)
    <<first::binary-size(4), rest::binary>> = response
    {:ok, transport} = FakeTransport.start_link([<<0xFF, first::binary>>, rest])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    request = {:read_holding_registers, 0, 2}

    assert Client.transaction(FakeTransport, transport, 1, request, 100) ==
             {:ok, [10, 258]}

    {:ok, request_pdu} = AVModbus.PDU.encode_request(request)
    {:ok, request_frame} = RTU.encode(1, request_pdu)
    assert FakeTransport.writes(transport) == [request_frame]
  end

  test "performs an ASCII transaction across partial reads and leading noise" do
    request = {:read_holding_registers, 0, 1}
    {:ok, response} = ASCII.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    <<first::binary-size(5), rest::binary>> = response
    {:ok, transport} = FakeTransport.start_link(["noise" <> first, rest])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(FakeTransport, transport, 1, request, 100, mode: :ascii) ==
             {:ok, [42]}

    {:ok, request_pdu} = AVModbus.PDU.encode_request(request)
    {:ok, request_frame} = ASCII.encode(1, request_pdu)
    assert FakeTransport.writes(transport) == [request_frame]
  end

  test "suppresses a fragmented ASCII adapter echo" do
    request = {:write_single_register, 1, 7}
    {:ok, request_pdu} = AVModbus.PDU.encode_request(request)
    {:ok, request_frame} = ASCII.encode(3, request_pdu)
    <<echo_head::binary-size(7), echo_tail::binary>> = request_frame

    {:ok, transport} =
      FakeTransport.start_link([echo_head, <<echo_tail::binary, request_frame::binary>>])

    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(FakeTransport, transport, 3, request, 100,
             mode: :ascii,
             echo: true
           ) == :ok
  end

  test "strips a fragmented adapter echo before decoding the response" do
    request = {:read_holding_registers, 0, 1}
    {:ok, request_pdu} = AVModbus.PDU.encode_request(request)
    {:ok, request_frame} = RTU.encode(1, request_pdu)
    {:ok, response_frame} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    <<echo_head::binary-size(3), echo_tail::binary>> = request_frame

    {:ok, transport} =
      FakeTransport.start_link([echo_head, <<echo_tail::binary, response_frame::binary>>])

    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(FakeTransport, transport, 1, request, 100, echo: true) ==
             {:ok, [42]}
  end

  test "does not accept a write echo as the device response" do
    request = {:write_single_register, 1, 7}
    {:ok, request_pdu} = AVModbus.PDU.encode_request(request)
    {:ok, request_frame} = RTU.encode(3, request_pdu)

    {:ok, echo_transport} = FakeTransport.start_link([request_frame])
    {:ok, plain_transport} = FakeTransport.start_link([request_frame])

    on_exit(fn ->
      if Process.alive?(echo_transport), do: Agent.stop(echo_transport)
      if Process.alive?(plain_transport), do: Agent.stop(plain_transport)
    end)

    assert Client.transaction(FakeTransport, echo_transport, 3, request, 100, echo: true) ==
             {:error, :timeout}

    assert Client.transaction(FakeTransport, plain_transport, 3, request, 100) == :ok
  end

  test "validates serial client options" do
    {:ok, transport} = FakeTransport.start_link([])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.start_link(FakeTransport, transport, echo: :yes) ==
             {:error, :invalid_echo_option}

    assert Client.start_link(FakeTransport, transport, turnaround: 0) ==
             {:error, :invalid_turnaround_option}

    assert Client.start_link(FakeTransport, transport, silence: 0) ==
             {:error, :invalid_silence_option}

    assert Client.start_link(FakeTransport, transport, gap: -1) ==
             {:error, :invalid_gap_option}

    assert Client.start_link(FakeTransport, transport, mode: :binary) ==
             {:error, :invalid_mode_option}

    assert Client.start_link(FakeTransport, transport, backoff: {10, 5}) ==
             {:error, :invalid_backoff_option}

    assert Client.start_link(FakeTransport, transport, timeout: 0) ==
             {:error, :invalid_timeout_option}

    assert Client.start_link(FakeTransport, transport, retry: 1) ==
             {:error, {:invalid_option, {:retry, 1}}}
  end

  test "returns Modbus exceptions" do
    {:ok, response} = RTU.encode(1, <<0x83, 0x02>>)
    {:ok, transport} = FakeTransport.start_link([response])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(
             FakeTransport,
             transport,
             1,
             {:read_holding_registers, 0, 1},
             100
           ) == {:error, {:exception, :illegal_data_address}}
  end

  test "performs a read/write multiple registers transaction" do
    request = {:read_write_multiple_registers, 3, 2, 14, [0x00FF, 0x0001]}
    {:ok, response} = RTU.encode(1, <<0x17, 0x04, 0x00, 0x2A, 0x01, 0x02>>)
    <<first::binary-size(3), rest::binary>> = response
    {:ok, transport} = FakeTransport.start_link([first, rest])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(FakeTransport, transport, 1, request, 100) ==
             {:ok, [42, 258]}

    {:ok, request_pdu} = AVModbus.PDU.encode_request(request)
    {:ok, request_frame} = RTU.encode(1, request_pdu)
    assert FakeTransport.writes(transport) == [request_frame]
  end

  test "performs a variable-length serial event log transaction" do
    response_pdu = <<0x0C, 0x08, 0x00, 0x00, 0x00, 0x03, 0x00, 0x05, 0x40, 0x20>>
    {:ok, response} = RTU.encode(1, response_pdu)
    <<first::binary-size(4), rest::binary>> = response
    {:ok, transport} = FakeTransport.start_link([first, rest])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(FakeTransport, transport, 1, :get_comm_event_log, 100) ==
             {:ok, %{status: 0, event_count: 3, message_count: 5, events: [0x40, 0x20]}}

    {:ok, request_frame} = RTU.encode(1, <<0x0C>>)
    assert FakeTransport.writes(transport) == [request_frame]
  end

  test "reads all device-identification pages" do
    page_one = <<0x2B, 0x0E, 0x01, 0x01, 0xFF, 0x03, 0x01, 0x00, 0x04, "Acme">>
    page_two = <<0x2B, 0x0E, 0x01, 0x01, 0x00, 0x00, 0x01, 0x03, 0x05, "Model">>
    {:ok, frame_one} = RTU.encode(1, page_one)
    {:ok, frame_two} = RTU.encode(1, page_two)
    {:ok, transport} = FakeTransport.start_link([frame_one, frame_two])
    {:ok, client} = Client.start_link(FakeTransport, transport)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    assert Client.read_device_identification(client, 1, :basic, 100) ==
             {:ok, %{0 => "Acme", 3 => "Model"}}

    {:ok, first_request} = RTU.encode(1, <<0x2B, 0x0E, 0x01, 0x00>>)
    {:ok, second_request} = RTU.encode(1, <<0x2B, 0x0E, 0x01, 0x03>>)
    assert FakeTransport.writes(transport) == [first_request, second_request]
  end

  test "reads a silence-delimited custom response" do
    {:ok, response_frame} = RTU.encode(1, <<100, 9, 8, 7>>)
    <<first::binary-size(3), rest::binary>> = response_frame
    {:ok, transport} = FakeTransport.start_link([<<0xFF, first::binary>>, rest])
    {:ok, client} = Client.start_link(FakeTransport, transport, silence: 1)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    assert Client.custom(client, 1, 100, <<1, 2>>, 100) == {:ok, <<9, 8, 7>>}
  end

  test "reads a silence-delimited encapsulated interface response" do
    {:ok, response_frame} = RTU.encode(1, <<0x2B, 13, 9, 8>>)
    {:ok, transport} = FakeTransport.start_link([response_frame])
    {:ok, client} = Client.start_link(FakeTransport, transport, silence: 1)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    assert Client.encapsulated_interface_transport(client, 1, 13, <<1, 2>>, 100) ==
             {:ok, <<9, 8>>}
  end

  test "applies one timeout deadline across partial reads" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    chunks = for <<byte <- response>>, do: {10, <<byte>>}
    {:ok, transport} = DelayedTransport.start_link(chunks)
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(
             DelayedTransport,
             transport,
             1,
             {:read_holding_registers, 0, 1},
             25
           ) == {:error, :timeout}
  end

  test "uses the managed serial default timeout unless a request overrides it" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {:ok, transport} = DelayedTransport.start_link([{20, response}])
    {:ok, client} = Client.start_link(DelayedTransport, transport, gap: 0, timeout: 5)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    assert Client.read_holding_registers(client, 1, 0, 1) == {:error, :timeout}
    assert Client.read_holding_registers(client, 1, 0, 1, timeout: 50) == {:ok, [42]}
  end

  test "allows an immediately available response with a zero timeout" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {:ok, transport} = FakeTransport.start_link([response])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(
             FakeTransport,
             transport,
             1,
             {:read_holding_registers, 0, 1},
             0,
             gap: 0
           ) == {:ok, [42]}
  end

  test "waits for the configured RTU gap before transmission" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {:ok, transport} = FakeTransport.start_link([response])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    started_at = System.monotonic_time(:millisecond)

    assert Client.transaction(
             FakeTransport,
             transport,
             1,
             {:read_holding_registers, 0, 1},
             100,
             gap: 20
           ) == {:ok, [42]}

    assert System.monotonic_time(:millisecond) - started_at >= 18
  end

  test "does not transmit when the RTU gap cannot fit the deadline" do
    {:ok, transport} = FakeTransport.start_link([])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(
             FakeTransport,
             transport,
             1,
             {:read_holding_registers, 0, 1},
             5,
             gap: 10
           ) == {:error, :timeout}

    assert FakeTransport.writes(transport) == []
  end

  test "managed client serializes concurrent transactions" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {:ok, transport} = ConcurrentTransport.start_link(response)
    {:ok, client} = Client.start_link(ConcurrentTransport, transport)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    requests =
      for _index <- 1..2 do
        Task.async(fn -> Client.read_holding_registers(client, 1, 0, 1, 100) end)
      end

    assert Enum.map(requests, &Task.await/1) == [{:ok, [42]}, {:ok, [42]}]
    assert ConcurrentTransport.max_active(transport) == 1
  end

  test "delivers a non-blocking request result to the caller" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {:ok, transport} = FakeTransport.start_link([response])
    {:ok, client} = Client.start_link(FakeTransport, transport, gap: 0)

    on_exit(fn ->
      stop_client(client)
      stop_agent(transport)
    end)

    reference = Client.send_request(client, 1, {:read_holding_registers, 0, 1}, 100)
    assert is_reference(reference)
    assert_receive {Client, ^reference, {:ok, [42]}}, 200
  end

  test "accepts timeout and recipient as non-blocking request options" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {:ok, transport} = FakeTransport.start_link([response])
    {:ok, client} = Client.start_link(FakeTransport, transport, gap: 0)
    caller = self()

    recipient =
      spawn(fn ->
        receive do
          message -> send(caller, {:forwarded, message})
        end
      end)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    reference =
      Client.send_request(client, 1, {:read_holding_registers, 0, 1},
        timeout: 100,
        to: recipient
      )

    assert is_reference(reference)
    assert_receive {:forwarded, {Client, ^reference, {:ok, [42]}}}, 200
  end

  test "delivers a managed ASCII request result asynchronously" do
    {:ok, response} = ASCII.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    <<first::binary-size(4), rest::binary>> = response
    {:ok, transport} = FakeTransport.start_link([first, rest])
    {:ok, client} = Client.start_link(FakeTransport, transport, mode: :ascii)

    on_exit(fn ->
      stop_client(client)
      stop_agent(transport)
    end)

    reference = Client.send_request(client, 1, {:read_holding_registers, 0, 1}, 100)
    assert_receive {Client, ^reference, {:ok, [42]}}, 200
  end

  test "includes async mailbox queueing in the configured default deadline" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {:ok, transport} = BlockingTransport.start_link(response)
    {:ok, client} = Client.start_link(BlockingTransport, transport, gap: 0, timeout: 5)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    first = Task.async(fn -> Client.read_holding_registers(client, 1, 0, 1, 100) end)
    assert_receive :transport_write
    assert_receive {:transport_read, reader}

    reference = Client.send_request(client, 1, {:read_holding_registers, 0, 1})
    Process.sleep(10)
    send(reader, :release_read)

    assert Task.await(first) == {:ok, [42]}
    assert_receive {Client, ^reference, {:error, :timeout}}, 200
    assert BlockingTransport.write_count(transport) == 1
  end

  test "validates non-blocking request submission" do
    {:ok, transport} = FakeTransport.start_link([])
    {:ok, client} = Client.start_link(FakeTransport, transport)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    assert Client.send_request(client, 248, {:read_holding_registers, 0, 1}) ==
             {:error, :invalid_unit_id}

    assert Client.send_request(client, 1, {:read_holding_registers, 0, 1}, -1) ==
             {:error, :invalid_timeout}

    assert Client.send_request(client, 0, {:read_holding_registers, 0, 1}) ==
             {:error, :invalid_broadcast_request}

    assert Client.send_request(client, 1, {:read_holding_registers, 0, 1}, 100, {1, 2}) ==
             {:error, :invalid_recipient}

    assert Client.send_request(client, 1, {:read_holding_registers, 0, 1}, timeout: -1) ==
             {:error, :invalid_timeout_option}

    assert Client.send_request(client, 1, {:read_holding_registers, 0, 1}, to: {1, 2}) ==
             {:error, :invalid_recipient}

    assert Client.send_request(client, 1, {:read_holding_registers, 0, 1}, retries: 1) ==
             {:error, {:invalid_option, {:retries, 1}}}
  end

  test "managed client does not send a request whose queue deadline expired" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {:ok, transport} = BlockingTransport.start_link(response)
    {:ok, client} = Client.start_link(BlockingTransport, transport)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    first = Task.async(fn -> Client.read_holding_registers(client, 1, 0, 1, 100) end)
    assert_receive :transport_write
    assert_receive {:transport_read, reader}

    second = Task.async(fn -> Client.read_holding_registers(client, 1, 0, 1, 5) end)
    Process.sleep(10)
    send(reader, :release_read)

    assert Task.await(first) == {:ok, [42]}
    assert Task.await(second) == {:error, :timeout}
    assert BlockingTransport.write_count(transport) == 1
  end

  test "starts disconnected and reopens an owned transport with backoff" do
    {:ok, transport_state} =
      ReopeningTransport.start_link([{:error, :device_missing}, {:ok, :reopened_uart}])

    {:ok, client} = Client.start_link(ReopeningTransport, gap: 0, backoff: {20, 20})

    assert Client.status(client) == {:disconnected, :device_missing}
    assert wait_until(fn -> Client.status(client) == :connected end)
    assert ReopeningTransport.open_count() == 2

    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    ReopeningTransport.push({:ok, response})

    assert Client.read_holding_registers(client, 1, 0, 1, 100) == {:ok, [42]}

    Client.close(client)
    assert ReopeningTransport.close_count() == 1
    Agent.stop(transport_state)
  end

  test "reopens an owned transport after a connected read failure" do
    {:ok, transport_state} =
      ReopeningTransport.start_link([{:ok, :first_uart}, {:ok, :second_uart}])

    {:ok, client} = Client.start_link(ReopeningTransport, gap: 0, backoff: {20, 20})
    ReopeningTransport.push({:error, :uart_failed})

    assert Client.read_holding_registers(client, 1, 0, 1, 100) == {:error, :closed}
    assert Client.status(client) == {:disconnected, :uart_failed}
    assert ReopeningTransport.close_count() == 1
    assert wait_until(fn -> Client.status(client) == :connected end)

    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    ReopeningTransport.push({:ok, response})
    assert Client.read_holding_registers(client, 1, 0, 1, 100) == {:ok, [42]}

    Client.close(client)
    assert ReopeningTransport.close_count() == 2
    Agent.stop(transport_state)
  end

  test "keeps an owned transport connected after a response timeout" do
    {:ok, transport_state} = ReopeningTransport.start_link([{:ok, :first_uart}])
    {:ok, client} = Client.start_link(ReopeningTransport, gap: 0, backoff: {20, 20})

    assert Client.read_holding_registers(client, 1, 0, 1, 10) == {:error, :timeout}
    assert Client.status(client) == :connected
    assert ReopeningTransport.open_count() == 1
    assert ReopeningTransport.close_count() == 0

    Client.close(client)
    assert ReopeningTransport.close_count() == 1
    Agent.stop(transport_state)
  end

  test "broadcasts writes without reading a response and observes turnaround" do
    {:ok, transport} = FakeTransport.start_link([])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    started_at = System.monotonic_time(:millisecond)

    assert Client.transaction(
             FakeTransport,
             transport,
             0,
             {:write_single_register, 10, 42},
             500
           ) == :ok

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    {:ok, request_frame} = RTU.encode(0, <<0x06, 0x00, 0x0A, 0x00, 0x2A>>)

    assert FakeTransport.writes(transport) == [request_frame]
    assert FakeTransport.read_count(transport) == 0
    assert elapsed_ms >= 90
  end

  test "managed client accepts broadcast writes" do
    {:ok, transport} = FakeTransport.start_link([])
    {:ok, client} = Client.start_link(FakeTransport, transport)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    assert Client.write_multiple_registers(client, 0, 4, [1, 2], 500) == :ok
    {:ok, request_frame} = RTU.encode(0, <<0x10, 0x00, 0x04, 0x00, 0x02, 0x04, 0, 1, 0, 2>>)

    assert FakeTransport.writes(transport) == [request_frame]
    assert FakeTransport.read_count(transport) == 0
  end

  test "drains a broadcast echo before the next managed transaction" do
    {:ok, broadcast_frame} =
      RTU.encode(0, <<0x10, 0x00, 0x04, 0x00, 0x02, 0x04, 0, 1, 0, 2>>)

    {:ok, response_frame} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {:ok, transport} = FakeTransport.start_link([broadcast_frame, response_frame])
    {:ok, client} = Client.start_link(FakeTransport, transport, echo: true, turnaround: 10)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    assert Client.write_multiple_registers(client, 0, 4, [1, 2], 100) == :ok
    assert Client.read_holding_registers(client, 1, 0, 1, 100) == {:ok, [42]}
    assert FakeTransport.read_count(transport) == 2
  end

  test "does not send a broadcast when its deadline cannot include turnaround" do
    {:ok, transport} = FakeTransport.start_link([])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(
             FakeTransport,
             transport,
             0,
             {:write_single_register, 10, 42},
             50
           ) == {:error, :timeout}

    assert FakeTransport.writes(transport) == []
  end

  test "rejects reads to the broadcast unit before writing" do
    {:ok, transport} = FakeTransport.start_link([])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(
             FakeTransport,
             transport,
             0,
             {:read_holding_registers, 0, 1},
             100
           ) == {:error, :invalid_broadcast_request}

    assert FakeTransport.writes(transport) == []
  end

  test "rejects invalid unit ids before writing" do
    {:ok, transport} = FakeTransport.start_link([])
    on_exit(fn -> if Process.alive?(transport), do: Agent.stop(transport) end)

    assert Client.transaction(
             FakeTransport,
             transport,
             248,
             {:read_holding_registers, 0, 1},
             100
           ) == {:error, :invalid_unit_id}

    assert FakeTransport.writes(transport) == []
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

  defp stop_client(client) do
    if Process.alive?(elem(client, 1)), do: Client.close(client)
  catch
    :exit, _reason -> :ok
  end

  defp stop_agent(agent) do
    if Process.alive?(agent), do: Agent.stop(agent)
  catch
    :exit, _reason -> :ok
  end
end
