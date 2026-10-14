defmodule AVModbus.TCPServerTest do
  use ExUnit.Case, async: true

  alias AVModbus.{Client, Memory, TCP}
  alias AVModbus.Server.TCP, as: TCPServer

  defp start_server(handler, options \\ []) do
    {:ok, server} =
      TCPServer.start_link(handler, [port: 0, address: {127, 0, 0, 1}] ++ options)

    on_exit(fn ->
      pid = server
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

    {:ok, client} =
      Client.start_link(transport: :tcp, host: "127.0.0.1", port: TCPServer.port(server))

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.stop(client)
      if Process.alive?(memory), do: :gen_server.stop(memory)
    end)

    assert Client.write_multiple_registers(client, 255, 3, [42, 258], timeout: 500) == :ok
    assert Client.read_holding_registers(client, 255, 3, 2, timeout: 500) == {:ok, [42, 258]}
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

  test "drains socket messages while preserving pipelined request order" do
    parent = self()

    handler = fn _unit_id, {:read_holding_registers, address, 1} ->
      if address == 0 do
        send(parent, {:slow_handler, self()})
        receive do: (:release -> :ok)
      end

      {:ok, [address]}
    end

    server = start_server(handler, max_buffer: 2_048, handler_timeout: 1_000)
    socket = connect(server)

    frames = for transaction_id <- 1..32, do: read_frame(transaction_id, transaction_id - 1)
    :ok = :gen_tcp.send(socket, frames)

    assert_receive {:slow_handler, handler_process}
    [connection] = Map.keys(:sys.get_state(server).clients)
    Process.sleep(20)
    assert {:message_queue_len, queued} = Process.info(connection, :message_queue_len)
    assert queued <= 1

    send(handler_process, :release)

    for transaction_id <- 1..32 do
      address = transaction_id - 1
      assert receive_frame(socket) == {:ok, transaction_id, 1, <<3, 2, address::16>>}
    end
  end

  test "closes a connection whose receive buffer exceeds its bound" do
    parent = self()

    handler = fn _unit_id, {:read_holding_registers, 0, 1} ->
      Process.flag(:trap_exit, true)
      send(parent, {:blocked_handler, self()})
      receive do: (:release -> {:ok, [0]})
    end

    server = start_server(handler, max_buffer: 260, handler_timeout: :infinity)
    socket = connect(server)
    :ok = :gen_tcp.send(socket, read_frame(1, 0))
    assert_receive {:blocked_handler, handler_process}
    handler_monitor = Process.monitor(handler_process)

    burst = for transaction_id <- 2..80, do: read_frame(transaction_id, 0)
    :ok = :gen_tcp.send(socket, burst)

    assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
    assert eventually(fn -> TCPServer.status(server) == {:listening, 0} end)
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler_process, :killed}
  end

  test "stops an active handler with its connection" do
    parent = self()

    handler = fn _unit_id, {:read_holding_registers, 0, 1} ->
      Process.flag(:trap_exit, true)
      send(parent, {:active_handler, self()})
      receive do: (:never -> {:ok, [0]})
    end

    server = start_server(handler, handler_timeout: :infinity)
    socket = connect(server)
    :ok = :gen_tcp.send(socket, read_frame(1, 0))
    assert_receive {:active_handler, handler_process}
    handler_monitor = Process.monitor(handler_process)

    :ok = TCPServer.stop(server)

    assert_receive {:DOWN, ^handler_monitor, :process, ^handler_process, :killed}
    assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
  end

  test "stops a trapping handler when its client disconnects" do
    parent = self()

    handler = fn _unit_id, {:read_holding_registers, 0, 1} ->
      Process.flag(:trap_exit, true)
      send(parent, {:disconnect_handler, self()})
      receive do: (:never -> {:ok, [0]})
    end

    server = start_server(handler, handler_timeout: :infinity)
    socket = connect(server)
    :ok = :gen_tcp.send(socket, read_frame(1, 0))
    assert_receive {:disconnect_handler, handler_process}
    handler_monitor = Process.monitor(handler_process)

    :ok = :gen_tcp.close(socket)

    assert_receive {:DOWN, ^handler_monitor, :process, ^handler_process, :killed}
    assert eventually(fn -> TCPServer.status(server) == {:listening, 0} end)
  end

  test "stops a trapping handler when its connection is evicted" do
    parent = self()

    handler = fn
      _unit_id, {:read_holding_registers, 0, 1} ->
        Process.flag(:trap_exit, true)
        send(parent, {:evicted_handler, self()})
        receive do: (:never -> {:ok, [0]})

      _unit_id, {:read_holding_registers, 1, 1} ->
        {:ok, [1]}
    end

    server = start_server(handler, connections: 1, handler_timeout: :infinity)
    first = connect(server)
    :ok = :gen_tcp.send(first, read_frame(1, 0))
    assert_receive {:evicted_handler, handler_process}
    handler_monitor = Process.monitor(handler_process)

    second = connect(server)

    assert exchange(second, 2, 1, <<3, 0, 1, 0, 1>>) == {:ok, 2, 1, <<3, 2, 0, 1>>}
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler_process, :killed}
    assert :gen_tcp.recv(first, 0, 1_000) == {:error, :closed}
  end

  test "listener kills a trapping handler when its broker is forcibly killed" do
    parent = self()

    handler = fn _unit_id, {:read_holding_registers, 0, 1} ->
      Process.flag(:trap_exit, true)
      send(parent, {:force_kill_handler, self()})
      receive do: (:never -> {:ok, [0]})
    end

    server = start_server(handler, handler_timeout: :infinity)
    socket = connect(server)
    :ok = :gen_tcp.send(socket, read_frame(1, 0))
    assert_receive {:force_kill_handler, handler_process}
    monitor = Process.monitor(handler_process)

    assert eventually(fn ->
             case :sys.get_state(server).clients |> Map.values() do
               [%{handler: ^handler_process}] -> true
               _ -> false
             end
           end)

    [broker] = Map.keys(:sys.get_state(server).clients)
    Process.exit(broker, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^handler_process, :killed}, 1_000
    assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
    assert eventually(fn -> TCPServer.status(server) == {:listening, 0} end)
  end

  test "server stop removes a broker admitted before socket handoff" do
    server = start_server(fn _unit_id, _request -> :ok end)
    {:ok, broker} = :gen_server.call(server, {:admit, {127, 0, 0, 1}})
    monitor = Process.monitor(broker)

    assert TCPServer.status(server) == {:listening, 1}
    assert :ok = TCPServer.stop(server)
    assert_receive {:DOWN, ^monitor, :process, ^broker, :normal}
  end

  test "evicts a broker admitted before handoff and serves the replacement" do
    server =
      start_server(fn _unit_id, {:read_holding_registers, 0, 1} -> {:ok, [42]} end,
        connections: 1
      )

    {:ok, waiting_broker} = :gen_server.call(server, {:admit, {127, 0, 0, 1}})
    monitor = Process.monitor(waiting_broker)
    socket = connect(server)

    assert exchange(socket, 1, 1, <<3, 0, 0, 0, 1>>) == {:ok, 1, 1, <<3, 2, 0, 42>>}
    assert_receive {:DOWN, ^monitor, :process, ^waiting_broker, :normal}
    assert TCPServer.status(server) == {:listening, 1}
  end

  test "eviction completes even when an old broker cannot receive stop" do
    server =
      start_server(fn _unit_id, {:read_holding_registers, 0, 1} -> {:ok, [42]} end,
        connections: 1
      )

    old_socket = connect(server)
    assert eventually(fn -> TCPServer.status(server) == {:listening, 1} end)
    [broker] = Map.keys(:sys.get_state(server).clients)
    monitor = Process.monitor(broker)

    :erlang.suspend_process(broker)
    started_at = System.monotonic_time(:millisecond)
    next_socket = connect(server)

    assert eventually(
             fn ->
               case Map.keys(:sys.get_state(server).clients) do
                 [next_broker] -> next_broker != broker
                 _ -> false
               end
             end,
             400
           )

    assert exchange(next_socket, 2, 1, <<3, 0, 0, 0, 1>>) == {:ok, 2, 1, <<3, 2, 0, 42>>}
    assert System.monotonic_time(:millisecond) - started_at < 2_500
    assert_receive {:DOWN, ^monitor, :process, ^broker, :killed}
    assert :gen_tcp.recv(old_socket, 0, 1_000) == {:error, :closed}
  end

  test "server stop is bounded when a broker is suspended" do
    parent = self()

    handler = fn _unit_id, {:read_holding_registers, 0, 1} ->
      Process.flag(:trap_exit, true)
      send(parent, {:suspended_handler, self()})
      receive do: (:never -> {:ok, [0]})
    end

    server = start_server(handler, handler_timeout: :infinity)
    socket = connect(server)
    :ok = :gen_tcp.send(socket, read_frame(1, 0))
    assert_receive {:suspended_handler, handler_process}
    handler_monitor = Process.monitor(handler_process)

    assert eventually(fn ->
             case :sys.get_state(server).clients |> Map.values() do
               [%{handler: ^handler_process}] -> true
               _ -> false
             end
           end)

    [broker] = Map.keys(:sys.get_state(server).clients)
    broker_monitor = Process.monitor(broker)
    :erlang.suspend_process(broker)

    started_at = System.monotonic_time(:millisecond)
    assert :ok = TCPServer.stop(server)
    assert System.monotonic_time(:millisecond) - started_at < 2_500
    assert_receive {:DOWN, ^broker_monitor, :process, ^broker, :killed}
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler_process, :killed}
    assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
  end

  test "server stop shares one deadline across unresponsive brokers" do
    server =
      start_server(fn _unit_id, {:read_holding_registers, 0, 1} -> {:ok, [42]} end,
        connections: 3
      )

    sockets = for _ <- 1..3, do: connect(server)
    assert eventually(fn -> TCPServer.status(server) == {:listening, 3} end)

    brokers = Map.keys(:sys.get_state(server).clients)
    monitors = Enum.map(brokers, &{&1, Process.monitor(&1)})
    Enum.each(brokers, &:erlang.suspend_process/1)

    started_at = System.monotonic_time(:millisecond)
    assert :ok = TCPServer.stop(server)
    assert System.monotonic_time(:millisecond) - started_at < 2_500

    for {broker, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^broker, :killed}
    end

    for socket <- sockets do
      assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
    end
  end

  test "request queued during slow eviction registers its handler and cleans up" do
    parent = self()

    handler = fn
      _unit_id, {:read_holding_registers, 22, 1} ->
        send(parent, {:concurrent_handler, self()})

        receive do
          :release -> {:ok, [22]}
        end

      _unit_id, {:read_holding_registers, address, 1} ->
        {:ok, [address]}
    end

    server = start_server(handler, connections: 2)
    old_socket = connect(server)
    assert eventually(fn -> TCPServer.status(server) == {:listening, 1} end)
    [old_broker] = Map.keys(:sys.get_state(server).clients)
    broker_monitor = Process.monitor(old_broker)

    live_socket = connect(server)
    assert eventually(fn -> TCPServer.status(server) == {:listening, 2} end)

    assert exchange(live_socket, 21, 1, <<3, 0, 21, 0, 1>>) ==
             {:ok, 21, 1, <<3, 2, 0, 21>>}

    # A suspended broker is a deterministic slow victim: eviction must use its
    # shared deadline and then force-terminate it before admitting a replacement.
    :erlang.suspend_process(old_broker)
    replacement_socket = connect(server)

    # Observe the stop request in the suspended victim's mailbox. This proves
    # that the listener is inside the bounded eviction wait without relying on
    # a scheduler-sensitive sleep.
    assert eventually(fn ->
             case Process.info(old_broker, :messages) do
               {:messages, messages} -> {TCPServer, :stop} in messages
               _ -> false
             end
           end)

    :ok = :gen_tcp.send(live_socket, read_frame(22, 22))

    # Normal requests update listener activity before starting a handler. That
    # call waits behind eviction; handler registration follows after it rather
    # than racing around the listener's lifecycle bookkeeping.
    assert eventually(fn ->
             case Process.info(server, :messages) do
               {:messages, messages} ->
                 Enum.any?(messages, fn
                   {:"$gen_call", _from, {:activity, _broker, _at}} -> true
                   _ -> false
                 end)

               _ ->
                 false
             end
           end)

    assert_receive {:DOWN, ^broker_monitor, :process, ^old_broker, :killed}, 3_000
    assert_receive {:concurrent_handler, handler_process}, 1_000
    handler_monitor = Process.monitor(handler_process)

    assert eventually(fn ->
             Enum.any?(:sys.get_state(server).clients, fn
               {_broker, %{handler: ^handler_process}} -> true
               _entry -> false
             end)
           end)

    send(handler_process, :release)
    assert receive_frame(live_socket, 3_000) == {:ok, 22, 1, <<3, 2, 0, 22>>}
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler_process, :normal}, 1_000

    assert exchange(replacement_socket, 23, 1, <<3, 0, 23, 0, 1>>) ==
             {:ok, 23, 1, <<3, 2, 0, 23>>}

    assert eventually(fn -> TCPServer.status(server) == {:listening, 2} end)
    assert :gen_tcp.recv(old_socket, 0, 1_000) == {:error, :closed}

    remaining_brokers = Map.keys(:sys.get_state(server).clients)
    remaining_monitors = Enum.map(remaining_brokers, &{&1, Process.monitor(&1)})

    :ok = :gen_tcp.close(live_socket)
    :ok = :gen_tcp.close(replacement_socket)

    for {broker, monitor} <- remaining_monitors do
      assert_receive {:DOWN, ^monitor, :process, ^broker, :normal}, 1_000
    end

    assert eventually(fn -> TCPServer.status(server) == {:listening, 0} end)
  end

  test "rapid admission and disconnect during eviction leaves the listener usable" do
    server =
      start_server(fn _unit_id, {:read_holding_registers, 0, 1} -> {:ok, [42]} end,
        connections: 1
      )

    # Closing immediately after connect races with accept, admit, and
    # controlling_process handover. Repeat without introducing test hooks.
    for _ <- 1..40 do
      socket = connect(server)
      :ok = :gen_tcp.close(socket)
    end

    assert eventually(fn -> TCPServer.status(server) == {:listening, 0} end, 300)
    socket = connect(server)
    assert exchange(socket, 41, 1, <<3, 0, 0, 0, 1>>) == {:ok, 41, 1, <<3, 2, 0, 42>>}
    assert :ok = TCPServer.stop(server)
    assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
  end

  test "server shutdown during concurrent socket admission does not hang" do
    server =
      start_server(fn _unit_id, {:read_holding_registers, 0, 1} -> {:ok, [42]} end,
        connections: 1
      )

    port = TCPServer.port(server)
    parent = self()

    connector =
      Task.async(fn ->
        send(parent, :admission_churn_started)

        for _ <- 1..40 do
          case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 200) do
            {:ok, socket} -> :ok = :gen_tcp.close(socket)
            {:error, _reason} -> :ok
          end
        end

        :ok
      end)

    assert_receive :admission_churn_started
    assert :ok = TCPServer.stop(server)
    assert Task.await(connector, 5_000) == :ok
  end

  test "recovers after repeated receive-buffer overload" do
    parent = self()

    handler = fn _unit_id, {:read_holding_registers, 0, 1} ->
      Process.flag(:trap_exit, true)
      send(parent, {:overload_handler, self()})
      receive do: (:never -> {:ok, [0]})
    end

    server = start_server(handler, max_buffer: 260, handler_timeout: :infinity)

    for cycle <- 1..10 do
      socket = connect(server)
      :ok = :gen_tcp.send(socket, read_frame(cycle, 0))
      assert_receive {:overload_handler, handler_process}
      handler_monitor = Process.monitor(handler_process)

      burst = for transaction_id <- 100..180, do: read_frame(transaction_id, 0)
      :ok = :gen_tcp.send(socket, burst)

      assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
      assert_receive {:DOWN, ^handler_monitor, :process, ^handler_process, :killed}
      assert eventually(fn -> TCPServer.status(server) == {:listening, 0} end)
    end

    socket = connect(server)
    assert eventually(fn -> TCPServer.status(server) == {:listening, 1} end)
    :ok = :gen_tcp.close(socket)
  end

  test "listens on an IPv6 address" do
    address = {0, 0, 0, 0, 0, 0, 0, 1}
    handler = fn _unit_id, {:read_holding_registers, 0, 1} -> {:ok, [42]} end

    {:ok, server} = TCPServer.start_link(handler, port: 0, address: address)

    on_exit(fn ->
      pid = server
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

    {:ok, client} =
      Client.start_link(transport: :tcp, host: {127, 0, 0, 1}, port: TCPServer.port(server))

    on_exit(fn -> if Process.alive?(elem(client, 1)), do: Client.stop(client) end)

    assert Client.read_coils(client, 1, 0, 1, timeout: 500) ==
             {:error, {:exception, :server_device_failure}}

    assert Client.read_coils(client, 1, 1, 1, timeout: 500) == {:ok, [true]}

    assert Client.write_single_register(client, 1, 0, 1, timeout: 500) ==
             {:error, {:exception, :illegal_function}}

    assert Client.read_device_identification(client, 1, timeout: 500) ==
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

    assert TCPServer.start_link(handler, max_buffer: 259) ==
             {:error, :invalid_max_buffer_option}

    assert TCPServer.start_link(handler, allow: [{{10, 0, 0, 0}, 40}]) ==
             {:error, :invalid_allow_option}

    :ok = TCPServer.stop(server)
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
    if Process.alive?(pid), do: TCPServer.stop(server)
  catch
    :exit, _reason -> :ok
  end

  defp read_frame(transaction_id, address) do
    {:ok, frame} = TCP.encode(transaction_id, 1, <<3, address::16, 1::16>>)
    frame
  end
end
