defmodule DisterlProbe.MailboxTest do
  use ExUnit.Case

  alias AVModbus.{PDU, RTU, Server}
  alias DisterlProbe.{Channel, Mailbox, Protocol}

  test "a 96-byte transport payload produces a 113-byte RTU frame" do
    {:ok, transport} = Protocol.encode(1, 1, 0, 0, :binary.copy(<<0xA5>>, 96))
    {:ok, pdu} = PDU.encode_request({:custom, 100, transport})
    {:ok, frame} = RTU.encode(1, pdu)

    assert byte_size(transport) == 109
    assert byte_size(pdu) == 110
    assert byte_size(frame) == 113
  end

  test "custom Modbus PDU carries queued bytes in both directions" do
    {:ok, mailbox} = Mailbox.start_link()
    assert :ok = Mailbox.queue(mailbox, "server message")
    {:ok, client} = Channel.queue(Channel.new(), "client message")

    {:ok, request} = Channel.packet(client)
    {:ok, request_pdu} = PDU.encode_request({:custom, 100, request})
    {:ok, request_frame} = RTU.encode(1, request_pdu)
    assert {:ok, 1, ^request_pdu} = RTU.decode(request_frame)

    assert {:ok, reply_pdu} = Server.respond({Mailbox, mailbox}, 1, request_pdu)
    assert {:ok, response} = PDU.decode_response({:custom, 100, request}, reply_pdu)
    {:ok, server_packet} = Protocol.decode(response)
    assert {:ok, client, "server message"} = Channel.receive_packet(client, server_packet)

    {:ok, ack_request} = Channel.packet(client)
    {:ok, ack_pdu} = PDU.encode_request({:custom, 100, ack_request})
    assert {:ok, ack_response_pdu} = Server.respond({Mailbox, mailbox}, 1, ack_pdu)

    assert {:ok, ack_response} =
             PDU.decode_response({:custom, 100, ack_request}, ack_response_pdu)

    {:ok, peer_ack} = Protocol.decode(ack_response)
    assert peer_ack.sequence == 0
    assert {:ok, done, nil} = Channel.receive_packet(client, peer_ack)
    assert Channel.done?(done)
  end

  test "bad custom payload yields a Modbus exception" do
    {:ok, mailbox} = Mailbox.start_link()
    assert {:ok, <<0xE4, 0x03>>} = Server.respond({Mailbox, mailbox}, 1, <<100, 2, 0, 0, 0, 0>>)
  end

  test "recovers from CRC errors, continuous timeouts, and lost responses" do
    {:ok, mailbox} = Mailbox.start_link()
    assert :ok = Mailbox.queue(mailbox, "server message")
    {:ok, client} = Channel.queue(Channel.new(), "client message")

    {:ok, request} = Channel.packet(client)
    {:ok, request_pdu} = PDU.encode_request({:custom, 100, request})
    {:ok, request_frame} = RTU.encode(1, request_pdu)

    assert {:error, :invalid_crc} = RTU.decode(corrupt_crc(request_frame))
    assert :sys.get_state(mailbox).received == 0

    # Model consecutive request timeouts before any frame reaches the server.
    Enum.each(1..8, fn _attempt ->
      assert Channel.packet(client) == {:ok, request}
    end)

    assert :sys.get_state(mailbox).received == 0
    assert {:ok, 1, ^request_pdu} = RTU.decode(request_frame)
    assert {:ok, response_pdu} = Server.respond({Mailbox, mailbox}, 1, request_pdu)
    {:ok, response_frame} = RTU.encode(1, response_pdu)
    assert :sys.get_state(mailbox).received == 1

    # Model responses lost after the server has accepted the request. Every
    # retry must produce the same response without delivering the request again.
    Enum.each(1..5, fn _attempt ->
      assert {:ok, duplicate_pdu} = Server.respond({Mailbox, mailbox}, 1, request_pdu)
      assert RTU.encode(1, duplicate_pdu) == {:ok, response_frame}
      assert :sys.get_state(mailbox).received == 1
    end)

    assert {:ok, 1, ^response_pdu} = RTU.decode(response_frame)
    assert {:ok, response} = PDU.decode_response({:custom, 100, request}, response_pdu)
    {:ok, server_packet} = Protocol.decode(response)
    assert {:ok, client, "server message"} = Channel.receive_packet(client, server_packet)

    {:ok, acknowledgment} = Channel.packet(client)
    {:ok, acknowledgment_pdu} = PDU.encode_request({:custom, 100, acknowledgment})
    assert {:ok, _final_response} = Server.respond({Mailbox, mailbox}, 1, acknowledgment_pdu)

    assert Channel.done?(client)
    assert Channel.done?(:sys.get_state(mailbox))
  end

  defp corrupt_crc(frame) do
    prefix_size = byte_size(frame) - 1
    <<prefix::binary-size(prefix_size), last>> = frame
    prefix <> <<Bitwise.bxor(last, 1)>>
  end
end
