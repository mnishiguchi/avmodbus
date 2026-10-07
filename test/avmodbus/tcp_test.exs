defmodule AVModbus.TCPTest do
  use ExUnit.Case, async: true

  alias AVModbus.TCP

  test "encodes and decodes an MBAP frame" do
    pdu = <<3, 0, 4, 0, 1>>

    assert TCP.encode(1, 255, pdu) ==
             {:ok, <<0, 1, 0, 0, 0, 6, 255, 3, 0, 4, 0, 1>>}

    assert TCP.decode(<<0, 1, 0, 0, 0, 6, 255, 3, 0, 4, 0, 1>>) ==
             {:ok, 1, 255, pdu, <<>>}
  end

  test "extracts one of several frames and retains a partial frame" do
    {:ok, first} = TCP.encode(1, 1, <<3, 0, 0, 0, 1>>)
    {:ok, second} = TCP.encode(2, 1, <<3, 0, 1, 0, 1>>)
    <<partial::binary-size(4), _rest::binary>> = second

    assert TCP.decode(first <> partial) ==
             {:ok, 1, 1, <<3, 0, 0, 0, 1>>, partial}

    assert TCP.decode(partial) == :more
  end

  test "reassembles a frame split at every byte boundary" do
    {:ok, frame} = TCP.encode(65_535, 255, <<0x10, 0, 1, 0, 2, 4, 0, 9, 0, 10>>)

    for cut <- 0..(byte_size(frame) - 1) do
      <<head::binary-size(cut), tail::binary>> = frame
      assert TCP.decode(head) == :more

      assert TCP.decode(head <> tail) ==
               {:ok, 65_535, 255, <<0x10, 0, 1, 0, 2, 4, 0, 9, 0, 10>>, <<>>}
    end
  end

  test "discards a complete frame for another protocol" do
    foreign = <<7::16, 1::16, 3::16, 1, 2, 3>>
    {:ok, next} = TCP.encode(8, 1, <<7>>)

    assert TCP.decode(binary_part(foreign, 0, byte_size(foreign) - 1)) == :more
    assert TCP.decode(foreign <> next) == {:discard, next}
  end

  test "rejects MBAP lengths outside the Modbus range" do
    assert TCP.decode(<<1::16, 0::16, 0::16, 1>>) == {:error, :invalid_length}
    assert TCP.decode(<<1::16, 0::16, 1::16, 1>>) == {:error, :invalid_length}
    assert TCP.decode(<<1::16, 0::16, 255::16, 1>>) == {:error, :invalid_length}

    assert {:ok, 1, 1, <<3, _rest::binary>>, <<>>} =
             TCP.decode(<<1::16, 0::16, 254::16, 1, 3, 0::2016>>)
  end

  test "enforces transaction, unit, and PDU bounds" do
    assert TCP.encode(-1, 1, <<3>>) == {:error, :invalid_transaction_id}
    assert TCP.encode(65_536, 1, <<3>>) == {:error, :invalid_transaction_id}
    assert TCP.encode(1, 256, <<3>>) == {:error, :invalid_unit_id}
    assert TCP.encode(1, 1, <<>>) == {:error, :invalid_pdu}
    assert TCP.encode(1, 1, :binary.copy(<<0>>, 254)) == {:error, :invalid_pdu}
    assert TCP.decode(:not_a_binary) == {:error, :invalid_frame}
  end
end
