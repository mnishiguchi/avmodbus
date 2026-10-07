defmodule AVModbus.ASCIITest do
  use ExUnit.Case, async: true

  alias AVModbus.ASCII

  test "calculates the specification LRC vector" do
    assert ASCII.lrc(<<17, 3, 0, 107, 0, 3>>) == 0x7E
  end

  test "encodes and decodes a complete frame" do
    assert ASCII.encode(17, <<3, 0, 107, 0, 3>>) == {:ok, ":1103006B00037E\r\n"}
    assert ASCII.decode(":1103006B00037E\r\n") == {:ok, 17, <<3, 0, 107, 0, 3>>}
    assert ASCII.decode(":1103006b00037e\r\n") == {:ok, 17, <<3, 0, 107, 0, 3>>}
  end

  test "supports another frame delimiter" do
    assert {:ok, frame} = ASCII.encode(1, <<3, 0, 0, 0, 1>>, ?!)
    assert frame == ":010300000001FB\r!"
    assert ASCII.split(frame, ?!) == {:ok, frame, <<>>}
    assert ASCII.decode(frame) == {:ok, 1, <<3, 0, 0, 0, 1>>}
  end

  test "rejects bad checksums and malformed frames" do
    assert ASCII.decode(":1103006B00037F\r\n") == {:error, :invalid_lrc}
    assert ASCII.decode(":11030\r\n") == {:error, :invalid_frame}
    assert ASCII.decode(":110X006B00037E\r\n") == {:error, :invalid_frame}
    assert ASCII.decode("1103006B00037E\r\n") == {:error, :invalid_frame}
  end

  test "extracts frames and resynchronizes at colons" do
    {:ok, frame} = ASCII.encode(1, <<3, 0, 0, 0, 1>>)

    assert ASCII.split("junk" <> frame <> ":01") == {:skip, frame <> ":01"}
    assert ASCII.split(frame <> ":01") == {:ok, frame, ":01"}
    assert ASCII.split(":0103") == :more
    assert ASCII.split(<<>>) == :more
    assert ASCII.split(":0103" <> frame) == {:skip, frame}
    assert ASCII.split("noise") == {:skip, <<>>}
  end

  test "reassembles a frame split at every byte boundary" do
    {:ok, frame} = ASCII.encode(7, <<0x10, 0, 1, 0, 2, 4, 0, 9, 0, 10>>)

    for cut <- 0..byte_size(frame) do
      <<head::binary-size(cut), tail::binary>> = frame

      case ASCII.split(head) do
        :more -> assert ASCII.split(head <> tail) == {:ok, frame, <<>>}
        {:ok, ^frame, <<>>} -> assert tail == <<>>
      end
    end
  end

  test "enforces frame and input bounds" do
    assert ASCII.encode(256, <<3>>) == {:error, :invalid_unit_id}
    assert ASCII.encode(1, <<>>) == {:error, :invalid_pdu}
    assert ASCII.encode(1, <<3>>, 256) == {:error, :invalid_delimiter}

    long = <<?:, :binary.copy("00", 300)::binary>>
    assert ASCII.split(long) == {:skip, <<>>}
  end
end
