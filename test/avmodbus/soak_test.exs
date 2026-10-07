defmodule AVModbus.SoakTest do
  use ExUnit.Case, async: false

  alias AVModbus.{Client, Memory}
  alias AVModbus.Server.ASCII, as: ASCIIServer
  alias AVModbus.Server.RTU, as: RTUServer
  alias AVModbus.Server.TCP, as: TCPServer
  alias AVModbus.Test.DuplexTransport

  @moduletag :soak
  @register_count 64
  @request_timeout 1_000
  @memory_growth_limit 4_096

  test "RTU, ASCII, and TCP client/server pairs remain correct and bounded" do
    duration_ms = soak_seconds() * 1_000
    interval_ms = soak_interval_ms()
    scenarios = start_scenarios(soak_transport())

    on_exit(fn -> Enum.each(scenarios, &stop_scenario/1) end)

    assert eventually(fn -> Enum.all?(scenarios, &connected?/1) end)
    Process.sleep(50)

    tracked = tracked_processes(scenarios)
    collect_garbage(tracked)
    processes_before = :erlang.system_info(:process_count)
    memory_before = process_memory(tracked)
    deadline = monotonic_ms() + duration_ms

    tasks =
      Enum.map(scenarios, fn scenario ->
        Task.async(fn -> exercise(scenario, deadline, interval_ms, 0) end)
      end)

    summaries = Enum.map(tasks, &Task.await(&1, duration_ms + 5_000))

    Process.sleep(100)
    collect_garbage(tracked)
    processes_after = :erlang.system_info(:process_count)
    memory_after = process_memory(tracked)

    assert Enum.all?(summaries, fn {_name, iterations} -> iterations > 0 end)
    assert processes_after <= processes_before + 2

    Enum.each(memory_before, fn {name, before_bytes} ->
      after_bytes = Map.fetch!(memory_after, name)

      assert after_bytes <= before_bytes + @memory_growth_limit,
             "#{name} process memory grew from #{before_bytes} to #{after_bytes} bytes"
    end)

    Enum.each(scenarios, fn scenario ->
      assert Process.alive?(client_pid(scenario.client))
      assert connected?(scenario)
    end)

    IO.puts(
      "soak complete: duration=#{duration_ms}ms interval=#{interval_ms}ms " <>
        "iterations=#{inspect(summaries)}, " <>
        "processes #{processes_before}->#{processes_after}, " <>
        "memory #{inspect(memory_before)}->#{inspect(memory_after)}"
    )
  end

  defp start_serial(mode) do
    {:ok, transport} = DuplexTransport.start_link()
    {:ok, memory} = Memory.start_link(holding_registers: @register_count)
    server_module = if mode == :rtu, do: RTUServer, else: ASCIIServer

    {:ok, server} =
      server_module.start_link(
        DuplexTransport,
        DuplexTransport.endpoint(transport, :b),
        {Memory, memory},
        units: [1],
        gap: 0,
        silence: 2
      )

    {:ok, client} =
      Client.start_link(
        DuplexTransport,
        DuplexTransport.endpoint(transport, :a),
        mode: mode,
        gap: 0,
        silence: 2
      )

    %{
      name: mode,
      client: client,
      server: server,
      server_module: server_module,
      memory: memory,
      transport: transport
    }
  end

  defp start_scenarios(:all), do: [start_serial(:rtu), start_serial(:ascii), start_tcp()]
  defp start_scenarios(:rtu), do: [start_serial(:rtu)]
  defp start_scenarios(:ascii), do: [start_serial(:ascii)]
  defp start_scenarios(:tcp), do: [start_tcp()]

  defp start_tcp do
    {:ok, memory} = Memory.start_link(holding_registers: @register_count)

    {:ok, server} =
      TCPServer.start_link({Memory, memory}, port: 0, address: {127, 0, 0, 1})

    {:ok, client} =
      Client.start_link(
        tcp: {127, 0, 0, 1},
        port: TCPServer.port(server),
        max_pending: 4
      )

    %{
      name: :tcp,
      client: client,
      server: server,
      server_module: TCPServer,
      memory: memory,
      transport: nil
    }
  end

  defp exercise(scenario, deadline, interval_ms, iterations) do
    if monotonic_ms() >= deadline do
      refute_receive {Client, reference, result},
                     50,
                     "unexpected duplicate result #{inspect(reference)}: #{inspect(result)}"

      {scenario.name, iterations}
    else
      address = rem(iterations, @register_count)
      value = rem(iterations, 65_536)

      write =
        Client.send_request(
          scenario.client,
          1,
          {:write_single_register, address, value},
          timeout: @request_timeout
        )

      read =
        Client.send_request(
          scenario.client,
          1,
          {:read_holding_registers, address, 1},
          timeout: @request_timeout
        )

      collect_results(%{write => :ok, read => {:ok, [value]}})
      if interval_ms > 0, do: Process.sleep(interval_ms)
      exercise(scenario, deadline, interval_ms, iterations + 1)
    end
  end

  defp collect_results(expected) when map_size(expected) == 0, do: :ok

  defp collect_results(expected) do
    receive do
      {Client, reference, result} ->
        case Map.pop(expected, reference) do
          {nil, _remaining} ->
            flunk("unexpected or duplicate result #{inspect(reference)}: #{inspect(result)}")

          {expected_result, remaining} ->
            assert result == expected_result
            collect_results(remaining)
        end
    after
      @request_timeout + 500 ->
        flunk("missing soak results for #{inspect(Map.keys(expected))}")
    end
  end

  defp tracked_processes(scenarios) do
    scenarios
    |> Enum.flat_map(fn scenario ->
      [
        {String.to_atom("#{scenario.name}_client"), client_pid(scenario.client)},
        {String.to_atom("#{scenario.name}_server"), server_pid(scenario.server)}
      ]
    end)
    |> Map.new()
  end

  defp collect_garbage(processes) do
    Enum.each(processes, fn {_name, pid} ->
      if Process.alive?(pid), do: :erlang.garbage_collect(pid)
    end)
  end

  defp process_memory(processes) do
    Map.new(processes, fn {name, pid} ->
      {:memory, bytes} = :erlang.process_info(pid, :memory)
      {name, bytes}
    end)
  end

  defp connected?(%{client: client, name: :tcp}), do: Client.status(client) == :connected
  defp connected?(%{client: client}), do: Client.status(client) == :connected

  defp stop_scenario(scenario) do
    stop(fn -> Client.stop(scenario.client) end)
    stop(fn -> scenario.server_module.stop(scenario.server) end)
    stop(fn -> GenServer.stop(scenario.memory) end)

    if scenario.transport,
      do: stop(fn -> GenServer.stop(scenario.transport) end)
  end

  defp stop(function) do
    function.()
  catch
    :exit, _reason -> :ok
  end

  defp client_pid({Client, pid}), do: pid
  defp client_pid({Client, pid, :tcp}), do: pid
  defp server_pid({_module, pid}), do: pid

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

  defp soak_seconds do
    case Integer.parse(System.fetch_env!("SOAK_SECONDS")) do
      {seconds, ""} when seconds > 0 -> seconds
      _other -> raise "SOAK_SECONDS must be a positive integer"
    end
  end

  defp soak_interval_ms do
    case Integer.parse(System.get_env("SOAK_INTERVAL_MS") || "5") do
      {milliseconds, ""} when milliseconds >= 0 -> milliseconds
      _other -> raise "SOAK_INTERVAL_MS must be a non-negative integer"
    end
  end

  defp soak_transport do
    case System.get_env("SOAK_TRANSPORT") || "all" do
      "all" -> :all
      "rtu" -> :rtu
      "ascii" -> :ascii
      "tcp" -> :tcp
      other -> raise "invalid SOAK_TRANSPORT: #{inspect(other)}"
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
