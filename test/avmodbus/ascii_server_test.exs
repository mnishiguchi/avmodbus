defmodule AVModbus.ASCIIServerTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias AVModbus.{ASCII, Memory, PDU}
  alias AVModbus.Server.ASCII, as: ASCIIServer

  defmodule FakeTransport do
    def start_link do
      owner = self()
      Agent.start_link(fn -> %{chunks: [], writes: [], owner: owner} end)
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
        send(state.owner, {:ascii_transport_write, data})
        %{state | writes: state.writes ++ [data]}
      end)
    end

    def writes(agent), do: Agent.get(agent, & &1.writes)
    def close(_agent), do: :ok
  end

  test "reassembles a noisy fragmented ASCII request and replies" do
    memory = start_supervised!({Memory, holding_registers: 10})
    :ok = Memory.put(memory, :holding_register, 2, [42])
    {transport, server} = start_server({Memory, memory})

    request = {:read_holding_registers, 2, 1}
    {:ok, pdu} = PDU.encode_request(request)
    {:ok, frame} = ASCII.encode(3, pdu)
    <<head::binary-size(5), tail::binary>> = frame

    FakeTransport.push(transport, "noise" <> head)
    FakeTransport.push(transport, tail)

    assert_receive {:ascii_transport_write, response}, 500
    assert {:ok, 3, response_pdu} = ASCII.decode(response)
    assert PDU.decode_response(request, response_pdu) == {:ok, [42]}
    stop_server(server, transport)
  end

  test "applies ASCII broadcast writes without replying" do
    memory = start_supervised!({Memory, holding_registers: 10})
    {transport, server} = start_server({Memory, memory})

    send_without_response(transport, 0, {:write_single_register, 1, 77})
    assert exchange(transport, 3, {:read_holding_registers, 1, 1}) == {:ok, [77]}
    stop_server(server, transport)
  end

  test "changes the ASCII input delimiter after replying with the old one" do
    memory = start_supervised!({Memory, holding_registers: 10})
    {transport, server} = start_server({Memory, memory})

    request = {:diagnostics, 3, [?! <<< 8]}
    assert exchange(transport, 3, request) == {:ok, [?! <<< 8]}
    assert List.last(FakeTransport.writes(transport)) |> :binary.last() == ?\n

    assert exchange(transport, 3, {:read_holding_registers, 0, 1}, ?!) == {:ok, [0]}
    assert List.last(FakeTransport.writes(transport)) |> :binary.last() == ?!
    stop_server(server, transport)
  end

  test "rejects delimiters that occur inside ASCII frames" do
    memory = start_supervised!({Memory, holding_registers: 10})
    {transport, server} = start_server({Memory, memory})

    assert exchange(transport, 3, {:diagnostics, 3, [?A <<< 8]}) ==
             {:error, {:exception, :illegal_data_value}}

    assert exchange(transport, 3, {:read_holding_registers, 0, 1}) == {:ok, [0]}
    stop_server(server, transport)
  end

  test "restart communications restores the line-feed delimiter" do
    memory = start_supervised!({Memory, holding_registers: 10})
    {transport, server} = start_server({Memory, memory})

    assert exchange(transport, 3, {:diagnostics, 3, [?! <<< 8]}) == {:ok, [?! <<< 8]}
    assert exchange(transport, 3, {:diagnostics, 1, [0]}, ?!) == {:ok, [0]}
    assert exchange(transport, 3, {:read_holding_registers, 0, 1}) == {:ok, [0]}
    stop_server(server, transport)
  end

  defp start_server(handler) do
    {:ok, transport} = FakeTransport.start_link()

    {:ok, server} =
      ASCIIServer.start_link(FakeTransport, transport, handler,
        units: [3],
        silence: 5,
        gap: 0
      )

    {transport, server}
  end

  defp stop_server(server, transport) do
    ASCIIServer.close(server)
    Agent.stop(transport)
  end

  defp exchange(transport, unit_id, request, delimiter \\ ?\n) do
    {:ok, request_pdu} = PDU.encode_request(request)
    {:ok, request_frame} = ASCII.encode(unit_id, request_pdu, delimiter)
    FakeTransport.push(transport, request_frame)

    assert_receive {:ascii_transport_write, response_frame}, 500
    assert :binary.last(response_frame) == delimiter
    assert {:ok, ^unit_id, response_pdu} = ASCII.decode(response_frame)
    PDU.decode_response(request, response_pdu)
  end

  defp send_without_response(transport, unit_id, request) do
    {:ok, request_pdu} = PDU.encode_request(request)
    {:ok, request_frame} = ASCII.encode(unit_id, request_pdu)
    FakeTransport.push(transport, request_frame)
    refute_receive {:ascii_transport_write, _response}, 30
  end
end
