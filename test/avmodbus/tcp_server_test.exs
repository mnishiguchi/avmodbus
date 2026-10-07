defmodule AVModbus.TCPServerTest do
  use ExUnit.Case, async: true

  alias AVModbus.{Client, Memory, TCP}
  alias AVModbus.Server.TCP, as: TCPServer

  defp start_server(handler, options \\ []) do
    {:ok, server} =
      TCPServer.start_link(handler, [port: 0, address: {127, 0, 0, 1}] ++ options)

    on_exit(fn ->
      pid = elem(server, 1)
      stop_server(server, pid)
    end)

    server
  end

  defp connect(server) do
    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        TCPServer.port(server),
        [:binary, active: false],
        1_000
      )

    socket
  end

  defp exchange(socket, transaction_id, unit_id, pdu) do
    {:ok, frame} = TCP.encode(transaction_id, unit_id, pdu)
    :ok = :gen_tcp.send(socket, frame)
    receive_frame(socket)
  end

  defp receive_frame(socket, timeout \\ 1_000) do
    with {:ok, <<transaction_id::16, 0::16, length::16>>} <-
           :gen_tcp.recv(socket, 6, timeout),
         {:ok, <<unit_id, pdu::binary>>} <- :gen_tcp.recv(socket, length, timeout) do
      {:ok, transaction_id, unit_id, pdu}
    end
  end

  test "serves the memory model through the managed TCP client" do
    {:ok, memory} = Memory.start_link(holding_registers: 20)
    server = start_server({Memory, memory})
    {:ok, client} = Client.start_link(tcp: "127.0.0.1", port: TCPServer.port(server))

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.close(client)
      if Process.alive?(memory), do: :gen_server.stop(memory)
    end)

    assert Client.write_multiple_registers(client, 255, 3, [42, 258], 500) == :ok
    assert Client.read_holding_registers(client, 255, 3, 2, 500) == {:ok, [42, 258]}
  end

  test "reassembles fragments and answers concatenated requests in order" do
    handler = fn
      _unit_id, {:read_holding_registers, address, 1} -> {:ok, [address + 100]}
    end

    server = start_server(handler)
    socket = connect(server)
    {:ok, first} = TCP.encode(10, 7, <<3, 0, 1, 0, 1>>)
    {:ok, second} = TCP.encode(11, 7, <<3, 0, 2, 0, 1>>)
    <<head::binary-size(4), tail::binary>> = first

    :ok = :gen_tcp.send(socket, head)
    :ok = :gen_tcp.send(socket, tail <> second)

    assert receive_frame(socket) == {:ok, 10, 7, <<3, 2, 0, 101>>}
    assert receive_frame(socket) == {:ok, 11, 7, <<3, 2, 0, 102>>}
  end

  test "answers malformed requests, discards foreign protocols, and keeps going" do
    handler = fn _unit_id, {:read_holding_registers, 0, 1} -> {:ok, [42]} end
    server = start_server(handler)
    socket = connect(server)

    assert exchange(socket, 1, 1, <<3, 0, 0, 0, 200>>) == {:ok, 1, 1, <<0x83, 3>>}
    assert exchange(socket, 2, 1, <<0x83, 0>>) == {:ok, 2, 1, <<0x83, 1>>}
    :ok = :gen_tcp.send(socket, <<3::16, 7::16, 3::16, 1, 2, 3>>)
    assert exchange(socket, 4, 1, <<3, 0, 0, 0, 1>>) == {:ok, 4, 1, <<3, 2, 0, 42>>}
  end

  test "closes a connection whose MBAP length cannot be recovered" do
    server = start_server(fn _unit_id, _request -> :ok end)
    socket = connect(server)
    :ok = :gen_tcp.send(socket, <<1::16, 0::16, 1_000::16, 1>>)
    assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
  end

  test "serves separate connections concurrently" do
    handler = fn
      _unit_id, {:read_holding_registers, 0, 1} ->
        Process.sleep(150)
        {:ok, [10]}

      _unit_id, {:read_holding_registers, 1, 1} ->
        {:ok, [20]}
    end

    server = start_server(handler)
    slow = connect(server)
    fast = connect(server)
    {:ok, slow_frame} = TCP.encode(1, 1, <<3, 0, 0, 0, 1>>)
    :ok = :gen_tcp.send(slow, slow_frame)

    assert exchange(fast, 2, 1, <<3, 0, 1, 0, 1>>) == {:ok, 2, 1, <<3, 2, 0, 20>>}
    assert receive_frame(slow) == {:ok, 1, 1, <<3, 2, 0, 10>>}
  end

  test "listens on an IPv6 address" do
    address = {0, 0, 0, 0, 0, 0, 0, 1}
    handler = fn _unit_id, {:read_holding_registers, 0, 1} -> {:ok, [42]} end

    {:ok, server} = TCPServer.start_link(handler, port: 0, address: address)

    on_exit(fn ->
      pid = elem(server, 1)
      if Process.alive?(pid), do: TCPServer.stop(server)
    end)

    {:ok, socket} =
      :gen_tcp.connect(address, TCPServer.port(server), [:inet6, :binary, active: false], 1_000)

    assert exchange(socket, 1, 1, <<3, 0, 0, 0, 1>>) == {:ok, 1, 1, <<3, 2, 0, 42>>}
  end

  test "evicts the least recently active connection when full" do
    handler = fn _unit_id, {:read_holding_registers, 0, 1} -> {:ok, [0]} end
    server = start_server(handler, connections: 2)
    first = connect(server)
    second = connect(server)
    assert eventually(fn -> TCPServer.status(server) == {:listening, 2} end)
    assert exchange(first, 1, 1, <<3, 0, 0, 0, 1>>) == {:ok, 1, 1, <<3, 2, 0, 0>>}
    Process.sleep(10)
    third = connect(server)

    assert exchange(third, 3, 1, <<3, 0, 0, 0, 1>>) == {:ok, 3, 1, <<3, 2, 0, 0>>}
    assert :gen_tcp.recv(second, 0, 1_000) == {:error, :closed}
    assert exchange(first, 2, 1, <<3, 0, 0, 0, 1>>) == {:ok, 2, 1, <<3, 2, 0, 0>>}
  end

  test "selects a fair eviction victim by address and age" do
    first = {10, 0, 0, 1}
    second = {10, 0, 0, 2}
    third = {10, 0, 0, 3}

    assert TCPServer.victim([{:p1, 5, first}, {:p2, 1, second}, {:p3, 9, third}], {10, 0, 0, 9}) ==
             :p2

    assert TCPServer.victim([{:p1, 5, first}, {:p2, 1, second}, {:p3, 9, third}], third) ==
             :p3

    assert TCPServer.victim(
             [{:p1, 5, first}, {:p2, 1, second}, {:p3, 7, first}, {:p4, 6, first}],
             second
           ) == :p1
  end

  test "enforces address allowlists including network prefixes" do
    assert TCPServer.allowed?({10, 1, 2, 3}, nil)
    assert TCPServer.allowed?({10, 1, 2, 3}, [{{10, 0, 0, 0}, 8}])
    refute TCPServer.allowed?({11, 1, 2, 3}, [{{10, 0, 0, 0}, 8}])
    assert TCPServer.allowed?({192, 168, 0, 5}, [{192, 168, 0, 5}])
    refute TCPServer.allowed?({192, 168, 0, 6}, [{192, 168, 0, 5}])

    server = start_server(fn _unit_id, _request -> :ok end, allow: [{{10, 0, 0, 0}, 8}])
    socket = connect(server)
    assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
  end

  test "closes a connection that never completes a request after its idle limit" do
    server = start_server(fn _unit_id, _request -> :ok end, idle: 80)
    socket = connect(server)

    for byte <- [0, 1, 0, 0] do
      :ok = :gen_tcp.send(socket, <<byte>>)
      Process.sleep(25)
    end

    assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
  end

  test "shares handler timeout, authorization, and identification policy" do
    handler = fn
      _unit_id, {:read_coils, 0, 1} -> Process.sleep(:infinity)
      _unit_id, {:read_coils, 1, 1} -> {:ok, [true]}
      _unit_id, _request -> :ok
    end

    authorize = fn _role, _unit_id, request ->
      not match?({:write_single_register, _, _}, request)
    end

    identification = %{0 => "AVModbus", 1 => "TCP", 2 => "0.1.0"}

    server =
      start_server(handler,
        handler_timeout: 50,
        authorize: authorize,
        identification: identification
      )

    {:ok, client} = Client.start_link(tcp: {127, 0, 0, 1}, port: TCPServer.port(server))
    on_exit(fn -> if Process.alive?(elem(client, 1)), do: Client.close(client) end)

    assert Client.read_coils(client, 1, 0, 1, 500) ==
             {:error, {:exception, :server_device_failure}}

    assert Client.read_coils(client, 1, 1, 1, 500) == {:ok, [true]}

    assert Client.write_single_register(client, 1, 0, 1, 500) ==
             {:error, {:exception, :illegal_function}}

    assert Client.read_device_identification(client, 1, :basic, 500) ==
             {:ok, identification}
  end

  test "returns listen errors, validates options, and closes clients on stop" do
    handler = fn _unit_id, _request -> :ok end
    server = start_server(handler)
    socket = connect(server)

    assert TCPServer.start_link(handler,
             port: TCPServer.port(server),
             address: {127, 0, 0, 1}
           ) == {:error, :eaddrinuse}

    assert TCPServer.start_link(handler, port: -1) == {:error, :invalid_port_option}
    assert TCPServer.start_link(handler, connections: 0) == {:error, :invalid_connections_option}
    assert TCPServer.start_link(handler, idle: 0) == {:error, :invalid_idle_option}

    assert TCPServer.start_link(handler, allow: [{{10, 0, 0, 0}, 40}]) ==
             {:error, :invalid_allow_option}

    :ok = TCPServer.close(server)
    assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
  end

  defp eventually(function, attempts \\ 100)
  defp eventually(_function, 0), do: false

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      Process.sleep(5)
      eventually(function, attempts - 1)
    end
  end

  defp stop_server(server, pid) do
    if Process.alive?(pid), do: TCPServer.close(server)
  catch
    :exit, _reason -> :ok
  end
end
