defmodule AVModbus.TCPServerLoadTest do
  use ExUnit.Case, async: false

  alias AVModbus.Client
  alias AVModbus.Server.TCP, as: TCPServer

  @client_count 8
  @requests_per_client 24

  test "serves concurrent clients correctly while handlers complete at different speeds" do
    {:ok, meter} = Agent.start_link(fn -> %{active: 0, maximum: 0, completed: 0} end)

    handler = fn unit_id, {:read_holding_registers, address, 1} ->
      enter_handler(meter)

      try do
        cond do
          address == 0 -> Process.sleep(40)
          rem(address, 7) == 0 -> Process.sleep(5)
          true -> :ok
        end

        {:ok, [unit_id * 1_000 + address]}
      after
        leave_handler(meter)
      end
    end

    {:ok, server} =
      TCPServer.start_link(handler,
        port: 0,
        address: {127, 0, 0, 1},
        connections: @client_count,
        handler_timeout: 1_000
      )

    clients =
      for unit_id <- 1..@client_count do
        {:ok, client} =
          Client.start_link(
            transport: :tcp,
            host: {127, 0, 0, 1},
            port: TCPServer.port(server),
            max_pending: 4
          )

        {unit_id, client}
      end

    on_exit(fn ->
      Enum.each(clients, fn {_unit_id, client} -> stop_client(client) end)
      stop_server(server)
      if Process.alive?(meter), do: Agent.stop(meter)
    end)

    assert eventually(fn -> TCPServer.status(server) == {:listening, @client_count} end)

    expected =
      for {unit_id, client} <- clients,
          address <- 0..(@requests_per_client - 1),
          into: %{} do
        reference =
          Client.send_request(
            client,
            unit_id,
            {:read_holding_registers, address, 1},
            timeout: 5_000
          )

        {reference, {:ok, [unit_id * 1_000 + address]}}
      end

    assert collect_results(map_size(expected), %{}) == expected
    refute_receive {Client, _reference, _duplicate}, 50

    assert %{active: 0, completed: completed, maximum: maximum} = Agent.get(meter, & &1)
    assert completed == @client_count * @requests_per_client
    assert maximum >= 2
  end

  test "samples broker mailbox and heap during a slow-handler TCP burst" do
    parent = self()

    handler = fn _unit_id, {:read_holding_registers, address, 1} ->
      if address == 0 do
        send(parent, {:resource_handler, self()})
        receive do: (:release -> :ok)
      end

      {:ok, [address]}
    end

    {:ok, server} =
      TCPServer.start_link(handler,
        address: {127, 0, 0, 1},
        port: 0,
        max_buffer: 2_048,
        handler_timeout: 3_000
      )

    on_exit(fn -> stop_server(server) end)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, TCPServer.port(server), [:binary, active: false])

    on_exit(fn -> :gen_tcp.close(socket) end)
    {:ok, first} = AVModbus.TCP.encode(1, 1, <<3, 0::16, 1::16>>)
    :ok = :gen_tcp.send(socket, first)
    assert_receive {:resource_handler, handler_process}

    [broker] = Map.keys(:sys.get_state(server).clients)
    {:links, links} = Process.info(broker, :links)
    [worker] = Enum.filter(links, fn link -> is_pid(link) and link != handler_process end)

    sampler =
      spawn_link(fn ->
        sample_connection(broker, worker, parent, %{
          samples: 0,
          broker: {0, 0, 0},
          worker: {0, 0, 0}
        })
      end)

    # 160 12-byte ADUs approach the 2,048-byte broker bound while the worker
    # is blocked in the first handler.
    for address <- 1..160 do
      {:ok, frame} = AVModbus.TCP.encode(address + 1, 1, <<3, address::16, 1::16>>)
      :ok = :gen_tcp.send(socket, frame)
      Process.sleep(1)
    end

    send(sampler, :finish)
    assert_receive {:connection_peak, samples, broker_peak, worker_peak}, 1_000
    assert samples > 0
    assert {broker_mailbox, broker_memory, broker_heap} = broker_peak
    assert {worker_mailbox, worker_memory, worker_heap} = worker_peak
    assert broker_mailbox >= 0
    assert worker_mailbox >= 0
    assert broker_memory > 0
    assert worker_memory > 0
    assert broker_heap > 0
    assert worker_heap > 0

    if System.get_env("AVMODBUS_PEAK_REPORT") do
      IO.puts(
        "tcp_receive_peak samples=#{samples} " <>
          "broker_mailbox=#{broker_mailbox} broker_memory_bytes=#{broker_memory} " <>
          "broker_heap_words=#{broker_heap} worker_mailbox=#{worker_mailbox} " <>
          "worker_memory_bytes=#{worker_memory} worker_heap_words=#{worker_heap}"
      )
    end

    send(handler_process, :release)

    for transaction_id <- 1..161 do
      {:ok, <<^transaction_id::16, 0::16, 5::16, 1, 3, 2, value::16>>} =
        :gen_tcp.recv(socket, 11, 1_000)

      assert value == transaction_id - 1
    end
  end

  defp sample_connection(broker, worker, owner, peaks) do
    next = %{
      samples: peaks.samples + 1,
      broker: process_peak(broker, peaks.broker),
      worker: process_peak(worker, peaks.worker)
    }

    receive do
      :finish -> send(owner, {:connection_peak, next.samples, next.broker, next.worker})
    after
      1 -> sample_connection(broker, worker, owner, next)
    end
  end

  defp process_peak(process, {mailbox_peak, memory_peak, heap_peak}) do
    case {
      Process.info(process, :message_queue_len),
      Process.info(process, :memory),
      Process.info(process, :heap_size)
    } do
      {{:message_queue_len, mailbox}, {:memory, memory}, {:heap_size, heap}} ->
        {max(mailbox_peak, mailbox), max(memory_peak, memory), max(heap_peak, heap)}

      _ ->
        {mailbox_peak, memory_peak, heap_peak}
    end
  end

  defp enter_handler(meter) do
    Agent.update(meter, fn state ->
      active = state.active + 1
      %{state | active: active, maximum: max(state.maximum, active)}
    end)
  end

  defp leave_handler(meter) do
    Agent.update(meter, fn state ->
      %{state | active: state.active - 1, completed: state.completed + 1}
    end)
  end

  defp collect_results(0, results), do: results

  defp collect_results(remaining, results) do
    receive do
      {Client, reference, result} ->
        refute Map.has_key?(results, reference), "duplicate result for #{inspect(reference)}"
        collect_results(remaining - 1, Map.put(results, reference, result))
    after
      6_000 -> flunk("timed out with #{remaining} TCP results still missing")
    end
  end

  defp eventually(function, attempts \\ 200)
  defp eventually(_function, 0), do: false

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      Process.sleep(5)
      eventually(function, attempts - 1)
    end
  end

  defp stop_client(client) do
    if Process.alive?(elem(client, 1)), do: Client.stop(client)
  catch
    :exit, _reason -> :ok
  end

  defp stop_server(server) do
    if Process.alive?(server), do: TCPServer.stop(server)
  catch
    :exit, _reason -> :ok
  end
end
