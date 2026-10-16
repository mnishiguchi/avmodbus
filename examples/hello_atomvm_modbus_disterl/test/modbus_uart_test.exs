defmodule DisterlProbe.ModbusUARTTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DisterlProbe.{Channel, ModbusUART, Protocol, ResponseFault, ResponseTimeout}

  test "chunks and reassembles a 64 KiB stream despite repeated lost responses" do
    pattern = for byte <- 0..255, into: <<>>, do: <<byte>>
    payload = :binary.copy(pattern, 256)
    expected_chunks = div(byte_size(payload) + Protocol.max_payload() - 1, Protocol.max_payload())

    channel =
      Channel.new(100,
        max_queued_bytes: byte_size(payload),
        max_queued_chunks: expected_chunks
      )

    {:ok, sender} = ModbusUART.queue_chunks(channel, payload)

    {sender, receiver, reassembled, chunks, retries} =
      transfer(sender, Channel.new(200), <<>>, 0, 0)

    assert Channel.done?(sender)
    assert receiver.received == expected_chunks
    assert chunks == expected_chunks
    assert retries == div(expected_chunks, 7)
    assert reassembled == payload
  end

  test "an empty write queues no transport message" do
    channel = Channel.new()
    assert ModbusUART.queue_chunks(channel, <<>>) == {:ok, channel}
  end

  test "open reuses an explicitly prepared adapter" do
    assert ModbusUART.open(existing: self()) == self()
    assert ModbusUART.open(existing: :not_a_pid) == {:error, :invalid_existing_adapter}
  end

  test "peer readiness follows channel session observation" do
    state = adapter_state(Channel.new(100))
    assert {:reply, false, ^state} = ModbusUART.handle_call(:peer_ready, :unused_from, state)

    ready = put_in(state.channel.peer_session, 200)
    assert {:reply, true, ^ready} = ModbusUART.handle_call(:peer_ready, :unused_from, ready)
  end

  test "uses a configured payload size below the wire protocol maximum" do
    payload = :binary.copy(<<0xA5>>, 300)
    assert {:ok, channel} = ModbusUART.queue_chunks(Channel.new(300), payload, 96)

    assert {1, first} = channel.outgoing
    assert byte_size(first) == 96

    assert Enum.map(Channel.pending_payloads(channel), &byte_size/1) == [
             96,
             96,
             12
           ]
  end

  test "rejects a multi-chunk write atomically when it exceeds the byte bound" do
    channel = Channel.new(400, max_queued_bytes: 191, max_queued_chunks: 10)
    payload = :binary.copy(<<0x5A>>, 192)

    assert ModbusUART.queue_chunks(channel, payload, 96) == {:error, :queue_full}
    assert Channel.done?(channel)
    assert channel.queued_bytes == 0
  end

  test "the default byte bound accepts 8 KiB exactly and rejects one more byte" do
    payload = :binary.copy(<<0xA5>>, 8_192)

    assert {:ok, channel} = ModbusUART.queue_chunks(Channel.new(500), payload, 96)
    assert channel.queued_bytes == 8_192
    assert channel.outstanding == 86
    assert Channel.queue(channel, <<0>>) == {:error, :queue_full}
  end

  test "a successful multi-chunk write switches to the bulk response timeout" do
    payload = :binary.copy(<<0xA5>>, 192)
    state = adapter_state(Channel.new(max_queued_bytes: 1_024, max_queued_chunks: 16))

    assert {:reply, :ok, next} = callback({:write, payload}, state)
    assert next.channel.queued_bytes == 192
    assert next.channel.outstanding == 2
    assert ResponseTimeout.current(next.response_timeout) == 2_000
    assert next.trace_queue_active
  end

  test "a queue-full write rolls the session and resets the receive stream" do
    {:ok, channel} =
      Channel.new(max_queued_bytes: 191, max_queued_chunks: 16)
      |> Channel.queue(:binary.copy(<<0x11>>, 96))

    old_session = channel.session

    state =
      channel
      |> adapter_state()
      |> Map.put(:rx_buffer, "stale receive stream")
      |> Map.put(:trace_queue_active, true)
      |> Map.update!(:response_timeout, &ResponseTimeout.observe_write(&1, 192, 96))

    assert {:reply, {:error, :queue_full}, next} =
             callback({:write, :binary.copy(<<0x22>>, 192)}, state)

    refute next.channel.session == old_session
    assert next.channel.peer_session == nil
    assert next.channel.max_queued_bytes == 191
    assert next.channel.max_queued_chunks == 16
    assert Channel.done?(next.channel)
    assert next.channel.queued_bytes == 0
    assert next.rx_buffer == <<>>
    assert ResponseTimeout.current(next.response_timeout) == 500
    refute next.trace_queue_active
  end

  test "a new read closes and replaces a stale blocked reader" do
    first_tag = make_ref()
    second_tag = make_ref()
    state = adapter_state(Channel.new())

    assert {:noreply, state} =
             ModbusUART.handle_call({:read, :infinity}, {self(), first_tag}, state)

    assert {:noreply, next} =
             ModbusUART.handle_call({:read, :infinity}, {self(), second_tag}, state)

    assert_receive {^first_tag, {:error, :closed}}
    assert {{reader_pid, ^second_tag}, reference, nil, :infinity} = next.reader
    assert reader_pid == self()
    assert is_reference(reference)
    refute_receive {^second_tag, _reply}
  end

  test "a peer session change closes an established infinite reader" do
    reader_tag = make_ref()
    channel = %{Channel.new(100) | peer_session: 200}

    state =
      channel
      |> adapter_state()
      |> Map.put(:role, :server)
      |> Map.put(:reader, {{self(), reader_tag}, make_ref(), nil, :infinity})
      |> Map.put(:response_fault, ResponseFault.new())
      |> Map.put(:rx_buffer, "stale receive stream")
      |> Map.update!(:response_timeout, &ResponseTimeout.observe_write(&1, 192, 96))

    {:ok, incoming} = Protocol.encode(201, 0, 0, 0, <<>>)

    assert {:reply, {:ok, response}, next} = callback({:exchange, incoming}, state)
    assert_receive {^reader_tag, {:error, :closed}}

    assert next.channel.peer_session == 201
    assert next.reader == nil
    assert next.rx_buffer == <<>>
    assert ResponseTimeout.current(next.response_timeout) == 500

    assert {:ok, packet} = Protocol.decode(response)
    assert packet.session == 100
    assert packet.acknowledged_session == 201
  end

  defp transfer(sender, receiver, reassembled, chunks, retries) do
    {:ok, request} = packet(sender)
    {:ok, receiver, delivered} = Channel.receive_packet(receiver, request)
    reassembled = reassembled <> delivered
    chunks = chunks + 1

    {receiver, retries} =
      if rem(chunks, 7) == 0 do
        # Model a response that was lost after the server accepted the request.
        # The client retransmits the same packet, which must not be delivered twice.
        assert {:ok, duplicate_receiver, nil} = Channel.receive_packet(receiver, request)
        {duplicate_receiver, retries + 1}
      else
        {receiver, retries}
      end

    {:ok, acknowledgment} = packet(receiver)
    {:ok, sender, nil} = Channel.receive_packet(sender, acknowledgment)

    if Channel.done?(sender) do
      {sender, receiver, reassembled, chunks, retries}
    else
      transfer(sender, receiver, reassembled, chunks, retries)
    end
  end

  defp packet(channel) do
    with {:ok, binary} <- Channel.packet(channel), do: Protocol.decode(binary)
  end

  defp adapter_state(channel) do
    %{
      channel: channel,
      chunk_payload_bytes: 96,
      reader: nil,
      response_timeout: ResponseTimeout.new(500, 2_000),
      rx_buffer: <<>>,
      trace_queue: false,
      trace_queue_active: false
    }
  end

  defp callback(message, state) do
    caller = self()

    capture_io(fn ->
      send(caller, {:callback_result, ModbusUART.handle_call(message, :unused_from, state)})
    end)

    assert_receive {:callback_result, result}
    result
  end
end
