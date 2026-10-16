defmodule DisterlProbe.ChannelTest do
  use ExUnit.Case, async: true

  alias DisterlProbe.{Channel, Protocol}

  test "restart preserves queue limits and creates a clean session boundary" do
    channel = Channel.new(100, max_queued_bytes: 192, max_queued_chunks: 2)
    assert {:ok, channel} = Channel.queue(channel, <<1>>)

    restarted = Channel.restart(channel, 200)

    assert restarted.session == 200
    assert restarted.peer_session == nil
    assert restarted.max_queued_bytes == 192
    assert restarted.max_queued_chunks == 2
    assert restarted.queued_bytes == 0
    assert restarted.outstanding == 0
    assert Channel.done?(restarted)
  end

  test "a rolled-over session discards both stale streams before bidirectional recovery" do
    client = Channel.new(100)
    server = Channel.new(200)

    {:ok, initial_poll} = packet(client)
    {:ok, server, nil} = Channel.receive_packet(server, initial_poll)
    {:ok, initial_response} = packet(server)
    {:ok, client, nil} = Channel.receive_packet(client, initial_response)

    {:ok, client} = Channel.queue(client, "stale client stream")
    {:ok, server} = Channel.queue(server, "stale server stream")

    client = Channel.restart(client, 101)
    {:ok, rollover_poll} = packet(client)
    {:ok, server, nil} = Channel.receive_packet(server, rollover_poll)

    assert server.peer_session == 101
    assert Channel.done?(server)
    assert server.queued_bytes == 0

    {:ok, rollover_response} = packet(server)
    {:ok, client, nil} = Channel.receive_packet(client, rollover_response)

    assert client.peer_session == 200
    assert Channel.done?(client)

    {:ok, client} = Channel.queue(client, "new client stream")
    {:ok, server} = Channel.queue(server, "new server stream")

    {:ok, request} = packet(client)
    {:ok, server, "new client stream"} = Channel.receive_packet(server, request)
    {:ok, response} = packet(server)
    {:ok, client, "new server stream"} = Channel.receive_packet(client, response)

    {:ok, final_ack} = packet(client)
    {:ok, server, nil} = Channel.receive_packet(server, final_ack)

    assert Channel.done?(client)
    assert Channel.done?(server)
  end

  test "exchanges independently queued messages and acknowledges both" do
    {:ok, a} = Channel.queue(Channel.new(), <<0, 1, 2>>)
    {:ok, b} = Channel.queue(Channel.new(), <<3, 4, 5>>)

    {:ok, request1} = Channel.packet(a)
    {:ok, packet1} = Protocol.decode(request1)
    {:ok, b, <<0, 1, 2>>} = Channel.receive_packet(b, packet1)

    {:ok, reply1} = Channel.packet(b)
    {:ok, response1} = Protocol.decode(reply1)
    {:ok, a, <<3, 4, 5>>} = Channel.receive_packet(a, response1)
    assert a.outgoing == nil
    assert b.outgoing != nil

    {:ok, request2} = Channel.packet(a)
    {:ok, packet2} = Protocol.decode(request2)
    {:ok, b, nil} = Channel.receive_packet(b, packet2)

    {:ok, reply2} = Channel.packet(b)
    {:ok, response2} = Protocol.decode(reply2)
    assert response2.sequence == 0
    assert {:ok, done, nil} = Channel.receive_packet(a, response2)
    assert Channel.done?(done)
  end

  test "duplicate request is delivered only once after a lost response" do
    {:ok, a} = Channel.queue(Channel.new(), "a")
    b = Channel.new()
    {:ok, bytes} = Channel.packet(a)
    {:ok, request} = Protocol.decode(bytes)

    assert {:ok, b, "a"} = Channel.receive_packet(b, request)
    assert {:ok, ^b, nil} = Channel.receive_packet(b, request)
  end

  test "queued messages remain ordered and only advance on acknowledgment" do
    {:ok, sender} = Channel.queue(Channel.new(), "one")
    {:ok, sender} = Channel.queue(sender, "two")
    {:ok, sender} = Channel.queue(sender, "three")
    receiver = Channel.new()

    {sender, receiver, delivered} = exchange(sender, receiver, [])
    assert delivered == ["one", "two", "three"]
    assert Channel.done?(sender)
    assert receiver.received == 3
  end

  test "a stale duplicate response neither redelivers nor skips the next message" do
    {:ok, sender} = Channel.queue(Channel.new(), "one")
    {:ok, sender} = Channel.queue(sender, "two")
    receiver = Channel.new()

    {:ok, first_bytes} = Channel.packet(sender)
    {:ok, first_packet} = Protocol.decode(first_bytes)
    {:ok, receiver, "one"} = Channel.receive_packet(receiver, first_packet)
    {:ok, first_ack_bytes} = Channel.packet(receiver)
    {:ok, first_ack} = Protocol.decode(first_ack_bytes)
    {:ok, sender, nil} = Channel.receive_packet(sender, first_ack)

    assert sender.outgoing == {2, "two"}
    assert {:ok, ^sender, nil} = Channel.receive_packet(sender, first_ack)

    {:ok, second_bytes} = Channel.packet(sender)
    {:ok, second_packet} = Protocol.decode(second_bytes)
    assert second_packet.sequence == 2
    assert {:ok, _receiver, "two"} = Channel.receive_packet(receiver, second_packet)
  end

  test "retry after a simulated timeout keeps the same wire packet" do
    {:ok, sender} = Channel.queue(Channel.new(), "retry me")
    {:ok, before_timeout} = Channel.packet(sender)

    # A timeout does not mutate the channel. The next client poll sends the
    # exact same sequence and payload, allowing the receiver to suppress it
    # if only the response was lost.
    {:ok, after_timeout} = Channel.packet(sender)
    assert after_timeout == before_timeout
  end

  test "a new peer session establishes a fresh receive baseline" do
    {:ok, old_peer} = Channel.queue(Channel.new(10), "old")
    receiver = Channel.new(20)

    {:ok, old_packet} = packet(old_peer)
    assert {:ok, receiver, "old"} = Channel.receive_packet(receiver, old_packet)

    {:ok, restarted_peer} = Channel.queue(Channel.new(11), "after reboot")
    {:ok, restarted_packet} = packet(restarted_peer)

    assert {:ok, receiver, "after reboot"} =
             Channel.receive_packet(receiver, restarted_packet)

    assert receiver.peer_session == 11
    assert receiver.received == 1
  end

  test "a peer restart discards byte-stream data queued for its old session" do
    {:ok, receiver} = Channel.queue(Channel.new(20), "stale response")
    {:ok, old_peer} = Channel.queue(Channel.new(10), "old request")
    {:ok, old_packet} = packet(old_peer)
    {:ok, receiver, "old request"} = Channel.receive_packet(receiver, old_packet)
    assert receiver.outgoing == {1, "stale response"}

    {:ok, restarted_peer} = Channel.queue(Channel.new(11), "new handshake")
    {:ok, restarted_packet} = packet(restarted_peer)

    assert {:ok, receiver, "new handshake"} =
             Channel.receive_packet(receiver, restarted_packet)

    assert receiver.outgoing == nil
    assert Channel.pending_payloads(receiver) == []
    assert receiver.queued_bytes == 0
    assert receiver.sent == 0
  end

  test "a new peer session ignores an acknowledgment made before session observation" do
    {:ok, local} = Channel.queue(Channel.new(20), "old one")
    {:ok, local} = Channel.queue(local, "old two")
    local = %{local | peer_session: 10}

    first_packet_from_restarted_peer = %{
      session: 11,
      sequence: 4,
      acknowledged_session: 20,
      acknowledgment: 2,
      payload: "new baseline"
    }

    assert {:ok, recovered, "new baseline"} =
             Channel.receive_packet(local, first_packet_from_restarted_peer)

    assert recovered.peer_session == 11
    assert recovered.received == 4
    assert recovered.outgoing == nil
    assert Channel.pending_payloads(recovered) == []
    assert recovered.queued_bytes == 0
    assert recovered.sent == 0
  end

  test "a rebooted receiver discards old-session data before accepting a new stream" do
    sender =
      Enum.reduce(1..7, Channel.new(30), fn sequence, channel ->
        {:ok, channel} = Channel.queue(channel, "message #{sequence}")
        channel
      end)

    receiver = receive_and_ack_all_but_last(sender, Channel.new(40), 6)
    restarted_receiver = Channel.new(41)

    {:ok, seventh_packet} = packet(receiver.sender)

    assert seventh_packet.sequence == 7
    assert seventh_packet.acknowledged_session == 40

    assert {:ok, ^restarted_receiver, nil} =
             Channel.receive_packet(restarted_receiver, seventh_packet)

    {:ok, restart_notice} = packet(restarted_receiver)

    assert {:ok, resynchronized_sender, nil} =
             Channel.receive_packet(receiver.sender, restart_notice)

    assert resynchronized_sender.peer_session == 41
    assert resynchronized_sender.outgoing == nil
    assert resynchronized_sender.sent == 0

    {:ok, resynchronized_sender} = Channel.queue(resynchronized_sender, "new handshake")
    {:ok, new_stream_packet} = packet(resynchronized_sender)

    assert {:ok, recovered, "new handshake"} =
             Channel.receive_packet(restarted_receiver, new_stream_packet)

    assert recovered.peer_session == 30
    assert recovered.received == 1
  end

  test "a packet for an old local session is ignored before peer observation" do
    {:ok, restarted} = Channel.queue(Channel.new(51), "new session data")

    stale_packet = %{
      session: 60,
      sequence: 7,
      acknowledged_session: 50,
      acknowledgment: 65_535,
      payload: "stale data"
    }

    assert {:ok, ^restarted, nil} = Channel.receive_packet(restarted, stale_packet)
    assert restarted.peer_session == nil

    current_packet = %{
      session: 61,
      sequence: 1,
      acknowledged_session: 0,
      acknowledgment: 0,
      payload: "current data"
    }

    assert {:ok, current, "current data"} = Channel.receive_packet(restarted, current_packet)
    assert current.peer_session == 61
  end

  test "sequence numbers wrap from 65,535 to 1 without duplicate delivery" do
    sender = %{Channel.new(80) | sent: 65_534}
    receiver = %{Channel.new(81) | peer_session: 80, received: 65_534}

    {:ok, sender} = Channel.queue(sender, "last")
    {:ok, last_packet} = packet(sender)
    assert last_packet.sequence == 65_535
    assert {:ok, receiver, "last"} = Channel.receive_packet(receiver, last_packet)
    assert {:ok, ^receiver, nil} = Channel.receive_packet(receiver, last_packet)

    {:ok, last_ack} = packet(receiver)
    {:ok, sender, nil} = Channel.receive_packet(sender, last_ack)

    {:ok, sender} = Channel.queue(sender, "wrapped")
    {:ok, wrapped_packet} = packet(sender)
    assert wrapped_packet.sequence == 1
    assert {:ok, receiver, "wrapped"} = Channel.receive_packet(receiver, wrapped_packet)
    assert {:ok, ^receiver, nil} = Channel.receive_packet(receiver, wrapped_packet)

    {:ok, wrapped_ack} = packet(receiver)
    assert {:ok, sender, nil} = Channel.receive_packet(sender, wrapped_ack)
    assert Channel.done?(sender)
    assert receiver.received == 1
  end

  test "stale acknowledgments remain valid across sequence wraparound" do
    {:ok, sender} = Channel.queue(%{Channel.new(90) | sent: 65_535}, "wrapped")
    sender = %{sender | peer_session: 91}

    stale_ack = %{
      session: 91,
      sequence: 0,
      acknowledged_session: 90,
      acknowledgment: 65_535,
      payload: <<>>
    }

    assert {:ok, unchanged, nil} = Channel.receive_packet(sender, stale_ack)
    assert unchanged.outgoing == {1, "wrapped"}

    future_ack = %{stale_ack | acknowledgment: 2}
    assert Channel.receive_packet(sender, future_ack) == {:error, :invalid_acknowledgment}
  end

  test "does not reuse a sequence while the complete sequence space is outstanding" do
    full = %{Channel.new() | outstanding: 65_535}
    assert Channel.queue(full, "one too many") == {:error, :queue_full}
  end

  test "bounds queued chunks and releases capacity after acknowledgment" do
    sender = Channel.new(100, max_queued_bytes: 100, max_queued_chunks: 2)
    {:ok, sender} = Channel.queue(sender, "one")
    {:ok, sender} = Channel.queue(sender, "two")

    assert Channel.queue(sender, "three") == {:error, :queue_full}
    assert sender.outstanding == 2
    assert sender.queued_bytes == 6

    receiver = Channel.new(200)
    {:ok, request} = packet(sender)
    {:ok, receiver, "one"} = Channel.receive_packet(receiver, request)
    {:ok, acknowledgment} = packet(receiver)
    {:ok, sender, nil} = Channel.receive_packet(sender, acknowledgment)

    assert sender.outstanding == 1
    assert sender.queued_bytes == 3
    assert {:ok, sender} = Channel.queue(sender, "three")
    assert Channel.pending_payloads(sender) == ["three"]
  end

  test "bounds queued payload bytes and preserves the original state when a write is rejected" do
    sender = Channel.new(100, max_queued_bytes: 5, max_queued_chunks: 10)
    {:ok, sender} = Channel.queue(sender, "abc")
    {:ok, sender} = Channel.queue(sender, "de")

    assert Channel.queue(sender, "f") == {:error, :queue_full}
    assert sender.outgoing == {1, "abc"}
    assert Channel.pending_payloads(sender) == ["de"]
    assert sender.queued_bytes == 5
  end

  test "rejects malformed data and out-of-order sequences" do
    assert Protocol.decode(<<2, 0, 1, 0, 0, 1>>) == {:error, :invalid_packet}
    assert Protocol.encode(1, 0, 0, 0, "x") == {:error, :invalid_packet}
    assert Protocol.encode(0, 1, 0, 0, "x") == {:error, :invalid_packet}
    assert Protocol.encode(1, 1, 0, 1, "x") == {:error, :invalid_packet}

    assert Protocol.encode(1, 1, 0, 0, :binary.copy(<<0>>, Protocol.max_payload() + 1)) ==
             {:error, :invalid_packet}

    assert Channel.queue(Channel.new(), <<>>) == {:error, :queue_unavailable}

    receiver = Channel.new(70)

    first = %{
      session: 71,
      sequence: 1,
      acknowledged_session: 0,
      acknowledgment: 0,
      payload: "one"
    }

    assert {:ok, receiver, "one"} = Channel.receive_packet(receiver, first)

    out_of_order = %{first | sequence: 3, payload: "three"}
    assert Channel.receive_packet(receiver, out_of_order) == {:error, :out_of_order}
  end

  test "reports the encoded empty-packet header size used by transaction tracing" do
    assert {:ok, packet} = Protocol.encode(1, 0, 0, 0, <<>>)
    assert byte_size(packet) == Protocol.header_size()
  end

  defp receive_and_ack_all_but_last(sender, receiver, 0),
    do: %{sender: sender, receiver: receiver}

  defp receive_and_ack_all_but_last(sender, receiver, remaining) do
    {:ok, incoming} = packet(sender)
    {:ok, receiver, _data} = Channel.receive_packet(receiver, incoming)
    {:ok, acknowledgment} = packet(receiver)
    {:ok, sender, nil} = Channel.receive_packet(sender, acknowledgment)
    receive_and_ack_all_but_last(sender, receiver, remaining - 1)
  end

  defp packet(channel) do
    with {:ok, binary} <- Channel.packet(channel), do: Protocol.decode(binary)
  end

  defp exchange(sender, receiver, delivered) do
    {:ok, bytes} = Channel.packet(sender)
    {:ok, packet} = Protocol.decode(bytes)
    {:ok, receiver, received} = Channel.receive_packet(receiver, packet)
    delivered = if received == nil, do: delivered, else: delivered ++ [received]

    {:ok, ack_bytes} = Channel.packet(receiver)
    {:ok, ack} = Protocol.decode(ack_bytes)
    {:ok, sender, nil} = Channel.receive_packet(sender, ack)

    if Channel.done?(sender) do
      {sender, receiver, delivered}
    else
      exchange(sender, receiver, delivered)
    end
  end
end
