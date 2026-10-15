defmodule DisterlProbe.MailboxTest do
  use ExUnit.Case

  alias AVModbus.{PDU, RTU, Server}
  alias DisterlProbe.{Channel, Mailbox, Protocol}

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
end
