defmodule AVModbus.SerialStreamStressTest do
  use ExUnit.Case, async: true

  alias AVModbus.{ASCII, PDU, RTU}
  alias AVModbus.Server.ASCII, as: ASCIIServer
  alias AVModbus.Server.RTU, as: RTUServer

  @request_count 128
  @chunk_sizes [1, 2, 7, 3, 16, 5, 31, 4, 11]

  defmodule BurstTransport do
    def start_link(chunks) do
      owner = self()
      Agent.start_link(fn -> %{chunks: chunks, owner: owner} end)
    end

    def read(transport, timeout_ms) do
      case Agent.get_and_update(transport, fn
             %{chunks: [chunk | rest]} = state -> {chunk, %{state | chunks: rest}}
             state -> {nil, state}
           end) do
        nil ->
          Process.sleep(timeout_ms)
          {:error, :timeout}

        :timeout ->
          {:error, :timeout}

        chunk ->
          {:ok, chunk}
      end
    end

    def write(transport, data) do
      send(Agent.get(transport, & &1.owner), {:stress_write, data})
      :ok
    end

    def close(_transport), do: :ok
  end

  test "RTU server remains synchronized through a noisy fragmented frame burst" do
    requests = requests()

    input =
      requests
      |> Enum.chunk_every(8)
      |> Enum.flat_map(fn group ->
        frames = Enum.map(group, &rtu_frame/1)
        corrupted_burst = chunks(corrupt_rtu(hd(frames))) ++ [:timeout]
        valid_burst = chunks(IO.iodata_to_binary([<<0xFF, 0xFE>> | frames])) ++ [:timeout]
        corrupted_burst ++ valid_burst
      end)

    {transport, server} = start_server(RTUServer, input, handler())
    responses = collect_responses(@request_count)

    Enum.zip(responses, requests)
    |> Enum.each(fn {response, request} ->
      assert {:ok, 3, pdu} = RTU.decode(response)
      assert PDU.decode_response(request, pdu) == expected(request)
    end)

    refute_receive {:stress_write, _unexpected}, 20
    stop_server(RTUServer, server, transport)
  end

  test "ASCII server remains synchronized through a noisy fragmented frame burst" do
    requests = requests()

    stream =
      requests
      |> Enum.with_index()
      |> Enum.map(fn {request, index} ->
        {:ok, pdu} = PDU.encode_request(request)
        {:ok, frame} = ASCII.encode(3, pdu)

        cond do
          rem(index, 16) == 0 -> ["junk", corrupt_ascii(frame), frame]
          rem(index, 5) == 0 -> ["noise", frame]
          true -> frame
        end
      end)
      |> IO.iodata_to_binary()

    {transport, server} = start_server(ASCIIServer, chunks(stream), handler())
    responses = collect_responses(@request_count)

    Enum.zip(responses, requests)
    |> Enum.each(fn {response, request} ->
      assert {:ok, 3, pdu} = ASCII.decode(response)
      assert PDU.decode_response(request, pdu) == expected(request)
    end)

    refute_receive {:stress_write, _unexpected}, 20
    stop_server(ASCIIServer, server, transport)
  end

  defp requests do
    for address <- 0..(@request_count - 1), do: {:read_holding_registers, address, 1}
  end

  defp handler do
    fn
      3, {:read_holding_registers, address, 1} -> {:ok, [address]}
      _unit_id, _request -> {:error, {:exception, :illegal_function}}
    end
  end

  defp expected({:read_holding_registers, address, 1}), do: {:ok, [address]}

  defp rtu_frame(request) do
    {:ok, pdu} = PDU.encode_request(request)
    {:ok, frame} = RTU.encode(3, pdu)
    frame
  end

  defp start_server(server_module, chunks, handler) do
    {:ok, transport} = BurstTransport.start_link(chunks)

    {:ok, server} =
      server_module.start_link(BurstTransport, transport, handler,
        units: [3],
        silence: 2,
        gap: 0
      )

    {transport, server}
  end

  defp stop_server(server_module, server, transport) do
    server_module.close(server)
    Agent.stop(transport)
  end

  defp collect_responses(count), do: collect_responses(count, [])
  defp collect_responses(0, responses), do: Enum.reverse(responses)

  defp collect_responses(count, responses) do
    receive do
      {:stress_write, response} -> collect_responses(count - 1, [response | responses])
    after
      2_000 -> flunk("timed out with #{count} serial responses still missing")
    end
  end

  defp corrupt_rtu(frame) do
    size = byte_size(frame)
    <<prefix::binary-size(size - 1), last>> = frame
    <<prefix::binary, Bitwise.bxor(last, 0x01)>>
  end

  defp corrupt_ascii(<<":03", rest::binary>>), do: <<":04", rest::binary>>

  defp chunks(data), do: chunks(data, @chunk_sizes, @chunk_sizes, [])
  defp chunks(<<>>, _sizes, _all_sizes, chunks), do: Enum.reverse(chunks)
  defp chunks(data, [], all_sizes, chunks), do: chunks(data, all_sizes, all_sizes, chunks)

  defp chunks(data, [size | sizes], all_sizes, chunks) do
    take = min(size, byte_size(data))
    <<chunk::binary-size(take), rest::binary>> = data
    chunks(rest, sizes, all_sizes, [chunk | chunks])
  end
end
