defmodule AVModbus.PropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Bitwise

  alias AVModbus.{ASCII, Client, PDU, RTU, TCP}
  alias AVModbus.Server.TCP, as: TCPServer

  @moduletag timeout: :infinity

  defp runs(default) do
    cond do
      System.get_env("FUZZ_SECONDS") -> 1_000_000_000
      value = System.get_env("FUZZ_RUNS") -> String.to_integer(value)
      true -> default
    end
  end

  defp run_time do
    case System.get_env("FUZZ_SECONDS") do
      nil -> nil
      value -> String.to_integer(value) * 1_000
    end
  end

  defp address, do: integer(0..65_535)
  defp byte_value, do: integer(0..255)
  defp word, do: integer(0..65_535)
  defp words(minimum, maximum), do: list_of(word(), min_length: minimum, max_length: maximum)
  defp bits(minimum, maximum), do: list_of(boolean(), min_length: minimum, max_length: maximum)

  defp address_and_count(maximum) do
    bind(integer(1..maximum), fn count ->
      map(integer(0..(65_536 - count)), &{&1, count})
    end)
  end

  defp address_and_values(values) do
    bind(values, fn generated ->
      map(integer(0..(65_536 - length(generated))), &{&1, generated})
    end)
  end

  defp file_group(value) do
    bind(integer(1..65_535), fn file ->
      bind(value, fn {count, generated} ->
        map(integer(0..(10_000 - count)), &{file, &1, generated})
      end)
    end)
  end

  defp request do
    one_of([
      map(address_and_count(2_000), fn {a, n} -> {:read_coils, a, n} end),
      map(address_and_count(2_000), fn {a, n} -> {:read_discrete_inputs, a, n} end),
      map(address_and_count(125), fn {a, n} -> {:read_holding_registers, a, n} end),
      map(address_and_count(125), fn {a, n} -> {:read_input_registers, a, n} end),
      map({address(), boolean()}, fn {a, value} -> {:write_single_coil, a, value} end),
      map({address(), word()}, fn {a, value} -> {:write_single_register, a, value} end),
      map(address_and_values(bits(1, 1_968)), fn {a, values} ->
        {:write_multiple_coils, a, values}
      end),
      map(address_and_values(words(1, 123)), fn {a, values} ->
        {:write_multiple_registers, a, values}
      end),
      map({address(), word(), word()}, fn {a, and_mask, or_mask} ->
        {:mask_write_register, a, and_mask, or_mask}
      end),
      bind({address_and_count(125), address_and_values(words(1, 121))}, fn
        {{read_address, read_count}, {write_address, write_values}} ->
          constant(
            {:read_write_multiple_registers, read_address, read_count, write_address,
             write_values}
          )
      end),
      map(address(), &{:read_fifo_queue, &1}),
      map(
        list_of(file_group(map(integer(1..8), &{&1, &1})), min_length: 1, max_length: 3),
        &{:read_file_record, &1}
      ),
      map(
        list_of(
          file_group(map(words(1, 8), &{length(&1), &1})),
          min_length: 1,
          max_length: 3
        ),
        &{:write_file_record, &1}
      ),
      map({member_of([:basic, :regular, :extended, :individual]), byte_value()}, fn
        {category, id} ->
          {:read_device_identification, category, id}
      end),
      constant(:read_exception_status),
      map(
        {member_of([1, 2, 3, 4, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20]), word()},
        fn {sub_function, value} -> {:diagnostics, sub_function, [value]} end
      ),
      map(words(0, 20), &{:diagnostics, 0, &1}),
      constant(:get_comm_event_counter),
      constant(:get_comm_event_log),
      constant(:report_server_id),
      map({member_of([0, 13, 15, 255]), binary(max_length: 32)}, fn {mei_type, data} ->
        {:encapsulated_interface_transport, mei_type, data}
      end),
      map({member_of([65, 72, 100, 110, 127]), binary(max_length: 32)}, fn {function, data} ->
        {:custom, function, data}
      end)
    ])
  end

  defp result({kind, _address, count}) when kind in [:read_coils, :read_discrete_inputs],
    do: map(bits(count, count), &{:ok, &1})

  defp result({kind, _address, count})
       when kind in [:read_holding_registers, :read_input_registers],
       do: map(words(count, count), &{:ok, &1})

  defp result({:read_write_multiple_registers, _read, count, _write, _values}),
    do: map(words(count, count), &{:ok, &1})

  defp result({:read_fifo_queue, _address}), do: map(words(0, 31), &{:ok, &1})

  defp result({:read_file_record, groups}) do
    groups
    |> Enum.map(fn {_file, _record, count} -> words(count, count) end)
    |> fixed_list()
    |> map(&{:ok, &1})
  end

  defp result(:read_exception_status), do: map(byte_value(), &{:ok, &1})

  defp result({:diagnostics, 0, data}), do: constant({:ok, data})

  defp result({:diagnostics, _sub_function, [_value]}),
    do: map(word(), &{:ok, [&1]})

  defp result(:get_comm_event_counter) do
    map({word(), word()}, fn {status, count} ->
      {:ok, %{status: status, event_count: count}}
    end)
  end

  defp result(:get_comm_event_log) do
    map({word(), word(), word(), list_of(byte_value(), max_length: 64)}, fn
      {status, event_count, message_count, events} ->
        {:ok,
         %{
           status: status,
           event_count: event_count,
           message_count: message_count,
           events: events
         }}
    end)
  end

  defp result(:report_server_id), do: map(binary(max_length: 64), &{:ok, &1})

  defp result({:read_device_identification, _category, _object_id}) do
    objects = list_of({byte_value(), binary(max_length: 12)}, max_length: 4)

    map({byte_value(), boolean(), byte_value(), objects}, fn {level, more, next, generated} ->
      {:ok,
       %{
         conformity_level: level,
         more_follows: more,
         next_object_id: next,
         objects: generated
       }}
    end)
  end

  defp result({kind, _, _}) when kind in [:encapsulated_interface_transport, :custom],
    do: map(binary(max_length: 64), &{:ok, &1})

  defp result(_write), do: constant(:ok)

  property "every valid request survives encoding and decoding" do
    check all(generated <- request(), max_runs: runs(100), max_run_time: run_time()) do
      assert {:ok, pdu} = PDU.encode_request(generated)
      assert byte_size(pdu) <= 253
      assert PDU.decode_request(pdu) == {:ok, generated}
      assert PDU.request_length(pdu) in [{:ok, byte_size(pdu)}, :unknown]
    end
  end

  property "every valid result survives encoding and decoding" do
    check all(
            generated_request <- request(),
            generated_result <- result(generated_request),
            max_runs: runs(100),
            max_run_time: run_time()
          ) do
      assert {:ok, pdu} = PDU.encode_response(generated_request, generated_result)
      assert byte_size(pdu) <= 253
      assert PDU.decode_response(generated_request, pdu) == generated_result

      assert PDU.response_length(generated_request, pdu) in [
               {:ok, byte_size(pdu)},
               :unknown
             ]
    end
  end

  property "arbitrary bytes never crash protocol decoders" do
    check all(
            bytes <- binary(max_length: 600),
            generated_request <- request(),
            max_runs: runs(1_000),
            max_run_time: run_time()
          ) do
      assert match?({:ok, _}, PDU.decode_request(bytes)) or
               match?({:error, _}, PDU.decode_request(bytes))

      assert match?({:ok, _}, PDU.decode_response(generated_request, bytes)) or
               match?(:ok, PDU.decode_response(generated_request, bytes)) or
               match?({:error, _}, PDU.decode_response(generated_request, bytes))

      TCP.decode(bytes)
      RTU.decode(bytes)
      RTU.split_request(bytes)
      RTU.split_response(bytes, 1, generated_request)
      ASCII.decode(bytes)
      ASCII.split(bytes)
    end
  end

  property "frames split at arbitrary boundaries are reassembled" do
    check all(
            requests <- list_of(request(), min_length: 1, max_length: 6),
            cuts <- list_of(integer(1..40), max_length: 10),
            max_runs: runs(100),
            max_run_time: run_time()
          ) do
      pdus = Enum.map(requests, fn request -> elem(PDU.encode_request(request), 1) end)

      tcp_frames =
        pdus
        |> Enum.with_index()
        |> Enum.map(fn {pdu, transaction} -> elem(TCP.encode(transaction, 1, pdu), 1) end)

      assert reassemble(chunks(IO.iodata_to_binary(tcp_frames), cuts), &tcp_frame/1) == tcp_frames

      known_pdus = Enum.filter(pdus, &match?({:ok, _}, PDU.request_length(&1)))
      rtu_frames = Enum.map(known_pdus, &elem(RTU.encode(1, &1), 1))

      assert reassemble(chunks(IO.iodata_to_binary(rtu_frames), cuts), &rtu_frame/1) ==
               rtu_frames

      ascii_frames = Enum.map(pdus, &elem(ASCII.encode(1, &1), 1))

      assert reassemble(chunks(IO.iodata_to_binary(ascii_frames), cuts), &ascii_frame/1) ==
               ascii_frames
    end
  end

  property "a running TCP server survives every well-framed PDU" do
    handler = fn _unit, _request -> {:error, {:exception, :illegal_function}} end
    {:ok, server} = TCPServer.start_link(handler, port: 0, address: {127, 0, 0, 1})
    on_exit(fn -> if Process.alive?(elem(server, 1)), do: TCPServer.close(server) end)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, TCPServer.port(server), [:binary, active: false])

    check all(
            pdu <- binary(min_length: 1, max_length: 253),
            max_runs: runs(300),
            max_run_time: run_time()
          ) do
      {:ok, frame} = TCP.encode(9, 1, pdu)
      :ok = :gen_tcp.send(socket, frame)
      assert {:ok, 9, 1, answer, <<>>} = receive_tcp_frame(socket)
      <<function, _rest::binary>> = pdu
      <<answered, _rest::binary>> = answer
      assert answered in [function, bor(function, 0x80)]
    end

    assert Process.alive?(elem(server, 1))
  end

  property "a running TCP client survives every well-framed answer" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    {:ok, client} = Client.start_link(tcp: {127, 0, 0, 1}, port: port, backoff: {1, 1})
    on_exit(fn -> if Process.alive?(elem(client, 1)), do: Client.close(client) end)
    {:ok, socket} = :gen_tcp.accept(listener, 1_000)

    check all(
            generated_request <- request(),
            answer <- binary(min_length: 1, max_length: 253),
            max_runs: runs(300),
            max_run_time: run_time()
          ) do
      reference = Client.send_request(client, 1, generated_request)
      assert {:ok, transaction, 1, _request_pdu, <<>>} = receive_tcp_frame(socket)
      {:ok, frame} = TCP.encode(transaction, 1, answer)
      :ok = :gen_tcp.send(socket, frame)
      assert_receive {Client, ^reference, result}, 1_000
      assert result == PDU.decode_response(generated_request, answer)
    end

    assert Process.alive?(elem(client, 1))
  end

  defp receive_tcp_frame(socket) do
    with {:ok, header} <- :gen_tcp.recv(socket, 6, 1_000),
         <<_transaction::16, _protocol::16, length::16>> <- header,
         {:ok, body} <- :gen_tcp.recv(socket, length, 1_000) do
      TCP.decode(header <> body)
    end
  end

  defp chunks(bytes, []), do: [bytes]
  defp chunks(<<>>, _cuts), do: []

  defp chunks(bytes, [cut | _cuts]) when cut >= byte_size(bytes), do: [bytes]

  defp chunks(bytes, [cut | cuts]) do
    <<chunk::binary-size(cut), rest::binary>> = bytes
    [chunk | chunks(rest, cuts)]
  end

  defp reassemble(chunks, decoder) do
    {frames, <<>>} =
      Enum.reduce(chunks, {[], <<>>}, fn chunk, {frames, buffer} ->
        {new_frames, rest} = take_frames(buffer <> chunk, decoder, [])
        {frames ++ new_frames, rest}
      end)

    frames
  end

  defp take_frames(buffer, decoder, frames) do
    case decoder.(buffer) do
      {:ok, frame, rest} -> take_frames(rest, decoder, [frame | frames])
      :more -> {Enum.reverse(frames), buffer}
    end
  end

  defp tcp_frame(buffer) do
    case TCP.decode(buffer) do
      {:ok, _transaction, _unit, _pdu, rest} ->
        size = byte_size(buffer) - byte_size(rest)
        <<frame::binary-size(size), _tail::binary>> = buffer
        {:ok, frame, rest}

      :more ->
        :more
    end
  end

  defp rtu_frame(buffer) do
    case RTU.split_request(buffer) do
      {:ok, frame, rest} -> {:ok, frame, rest}
      :more -> :more
    end
  end

  defp ascii_frame(buffer) do
    case ASCII.split(buffer) do
      {:ok, frame, rest} -> {:ok, frame, rest}
      :more -> :more
    end
  end
end
