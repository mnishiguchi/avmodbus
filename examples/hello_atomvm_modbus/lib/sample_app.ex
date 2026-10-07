defmodule SampleApp do
  @moduledoc """
  Modbus RTU / ASCII / TCP の client または server として動作する最小 AtomVM example です。
  """

  alias AVModbus.{ASCII, Client, Memory, TCP}
  alias AVModbus.Server.TCP, as: TCPServer

  @role Application.compile_env(:sample_app, :modbus_role, :client)
  @mode Application.compile_env(:sample_app, :modbus_mode, :rtu)
  @tcp_host Application.compile_env(:sample_app, :modbus_tcp_host, "127.0.0.1")
  @tcp_port Application.compile_env(:sample_app, :modbus_tcp_port, 502)
  @unit_id Application.compile_env(:sample_app, :modbus_unit_id, 1)
  @start_address Application.compile_env(:sample_app, :modbus_start_address, 0)
  @quantity Application.compile_env(:sample_app, :modbus_quantity, 1)
  @timeout_ms Application.compile_env(:sample_app, :modbus_response_timeout_ms, 1_000)
  @interval_ms Application.compile_env(:sample_app, :modbus_request_interval_ms, 5_000)
  @health_interval_ms Application.compile_env(:sample_app, :modbus_health_interval_ms, 0)
  @measure_memory Application.compile_env(:sample_app, :measure_memory, false)
  @identification %{
    0 => "AVModbus",
    1 => "Seeed Studio XIAO ESP32-C5",
    2 => "0.1.0"
  }

  def start do
    :ok = framing_smoke_test()
    baseline = memory_snapshot()

    case @role do
      :client -> start_client(baseline)
      :server -> start_server(baseline)
    end
  end

  defp framing_smoke_test do
    pdu = <<3, 0, 0, 0, 1>>

    with {:ok, ascii_frame} <- ASCII.encode(@unit_id, pdu),
         {:ok, @unit_id, ^pdu} <- ASCII.decode(ascii_frame),
         {:ok, tcp_frame} <- TCP.encode(1, @unit_id, pdu),
         {:ok, 1, @unit_id, ^pdu, <<>>} <- TCP.decode(tcp_frame) do
      :ok
    end
  end

  defp start_client(baseline) do
    options =
      if @mode == :tcp,
        do: [tcp: @tcp_host, port: @tcp_port, timeout: @timeout_ms],
        else: [mode: @mode, timeout: @timeout_ms]

    case Client.start_link(options) do
      {:ok, client} ->
        processes = client_processes(client)
        report_memory(baseline, processes)
        start_health_monitor(:client, nil, client, processes)
        client_loop(client)

      {:error, reason} ->
        IO.puts("modbus: failed to start client: #{inspect(reason)}")
        Process.sleep(:infinity)
    end
  end

  defp start_server(baseline) do
    with {:ok, memory} <- Memory.start_link(),
         {:ok, server_module, server} <- start_mode_server({Memory, memory}) do
      report_server_status(server_module, server)
      processes = server_processes(memory, server)
      report_memory(baseline, processes)
      start_health_monitor(:server, server_module, server, processes)

      server_loop(server)
    else
      {:error, reason} ->
        IO.puts("modbus: failed to start server: #{inspect(reason)}")
        Process.sleep(:infinity)
    end
  end

  if @mode == :tcp do
    defp start_mode_server(handler) do
      case TCPServer.start_link(handler, port: @tcp_port, identification: @identification) do
        {:ok, server} -> {:ok, TCPServer, server}
        {:error, _reason} = error -> error
      end
    end
  else
    defp start_mode_server(handler) do
      server_module =
        if @mode == :ascii, do: AVModbus.Server.ASCII, else: AVModbus.Server.RTU

      case server_module.start_link(
             handler,
             units: [@unit_id],
             identification: @identification
           ) do
        {:ok, server} -> {:ok, server_module, server}
        {:error, _reason} = error -> error
      end
    end
  end

  defp report_server_status(TCPServer, server) do
    {:listening, connections} = TCPServer.status(server)

    IO.puts(
      "modbus: tcp server listening on port #{TCPServer.port(server)}, #{connections} connections"
    )
  end

  defp report_server_status(server_module, server) do
    case server_module.status(server) do
      :connected ->
        IO.puts("modbus: #{@mode} server ready for unit #{@unit_id}")

      {:disconnected, reason} ->
        IO.puts("modbus: #{@mode} server reconnecting after #{inspect(reason)}")
    end
  end

  defp client_loop(client) do
    request = {:read_holding_registers, @start_address, @quantity}

    case Client.send_request(client, @unit_id, request) do
      reference when is_reference(reference) ->
        receive do
          {Client, ^reference, {:ok, registers}} ->
            IO.puts("modbus: registers #{inspect(registers)}")

          {Client, ^reference, {:error, reason}} ->
            IO.puts("modbus: request failed #{inspect(reason)}")
        end

      {:error, reason} ->
        IO.puts("modbus: request rejected #{inspect(reason)}")
    end

    Process.sleep(@interval_ms)
    client_loop(client)
  end

  defp server_loop(server) do
    Process.sleep(@interval_ms)
    server_loop(server)
  end

  if @measure_memory or @health_interval_ms > 0 do
    defp memory_snapshot do
      true = :erlang.garbage_collect()

      %{
        free_heap: :erlang.system_info(:esp32_free_heap_size),
        largest_free_block: :erlang.system_info(:esp32_largest_free_block),
        minimum_free: :erlang.system_info(:esp32_minimum_free_size),
        binary: :erlang.memory(:binary),
        process_count: :erlang.system_info(:process_count)
      }
    end

    defp process_memory(processes) do
      Enum.map(processes, fn {name, pid} ->
        {name,
         :erlang.process_info(pid, [
           :memory,
           :heap_size,
           :stack_size,
           :message_queue_len
         ])}
      end)
    end

    defp client_processes({Client, pid}), do: [client: pid]
    defp client_processes({Client, pid, :tcp}), do: [client: pid]

    defp server_processes(memory, {_module, pid}),
      do: [memory: memory, server: pid]
  else
    defp memory_snapshot, do: nil
    defp client_processes(_client), do: []
    defp server_processes(_memory, _server), do: []
  end

  if @measure_memory do
    defp report_memory(before, processes) do
      Process.sleep(100)

      Enum.each(processes, fn {_name, pid} ->
        true = :erlang.garbage_collect(pid)
      end)

      after_start = memory_snapshot()

      IO.puts(
        "modbus_memory " <>
          "role=#{@role} mode=#{@mode} " <>
          "free_before=#{before.free_heap} free_after=#{after_start.free_heap} " <>
          "free_delta=#{before.free_heap - after_start.free_heap} " <>
          "largest_free=#{after_start.largest_free_block} " <>
          "minimum_free=#{after_start.minimum_free} " <>
          "binary_before=#{before.binary} binary_after=#{after_start.binary} " <>
          "processes_before=#{before.process_count} " <>
          "processes_after=#{after_start.process_count} " <>
          "process_memory=#{inspect(process_memory(processes))}"
      )
    end
  else
    defp report_memory(_baseline, _processes), do: :ok
  end

  if @health_interval_ms > 0 do
    defp start_health_monitor(kind, server_module, resource, processes) do
      spawn(fn ->
        started_at = :erlang.monotonic_time(:millisecond)
        health_loop(kind, server_module, resource, processes, started_at, 1)
      end)

      :ok
    end

    defp health_loop(kind, server_module, resource, processes, started_at, sequence) do
      Process.sleep(@health_interval_ms)
      snapshot = memory_snapshot()
      uptime_ms = :erlang.monotonic_time(:millisecond) - started_at
      status = resource_status(kind, server_module, resource)

      IO.puts(
        "modbus_health " <>
          "sequence=#{sequence} uptime_ms=#{uptime_ms} role=#{@role} mode=#{@mode} " <>
          "status=#{inspect(status)} free_heap=#{snapshot.free_heap} " <>
          "largest_free=#{snapshot.largest_free_block} minimum_free=#{snapshot.minimum_free} " <>
          "binary=#{snapshot.binary} process_count=#{snapshot.process_count} " <>
          "process_memory=#{inspect(process_memory(processes))}"
      )

      health_loop(kind, server_module, resource, processes, started_at, sequence + 1)
    end

    defp resource_status(:client, _server_module, client), do: Client.status(client)

    defp resource_status(:server, server_module, server),
      do: server_module.status(server)
  else
    defp start_health_monitor(_kind, _server_module, _resource, _processes), do: :ok
  end
end
