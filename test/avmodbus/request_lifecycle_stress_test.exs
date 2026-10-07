defmodule AVModbus.RequestLifecycleStressTest do
  use ExUnit.Case, async: false

  alias AVModbus.{Client, RTU}
  alias AVModbus.Server.TCP, as: TCPServer

  @serial_queued_requests 64
  @tcp_requests 64
  @deadline_slack_ms 75

  defmodule DeadlineTransport do
    def start_link(response) do
      owner = self()
      Agent.start_link(fn -> %{owner: owner, response: response, reads: 0, writes: 0} end)
    end

    def write(agent, _frame) do
      Agent.update(agent, fn state ->
        send(state.owner, {:serial_write, state.writes + 1})
        %{state | writes: state.writes + 1}
      end)
    end

    def read(agent, timeout_ms) do
      {owner, response, read_number} =
        Agent.get_and_update(agent, fn state ->
          read_number = state.reads + 1
          {{state.owner, state.response, read_number}, %{state | reads: read_number}}
        end)

      send(owner, {:serial_read, read_number})

      if read_number == 1 do
        Process.sleep(timeout_ms)
        {:error, :timeout}
      else
        {:ok, response}
      end
    end

    def write_count(agent), do: Agent.get(agent, & &1.writes)
  end

  test "serial requests report once by their deadline while queued behind a slow transaction" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {:ok, transport} = DeadlineTransport.start_link(response)
    {:ok, client} = Client.start_link(DeadlineTransport, transport, gap: 0)

    on_exit(fn ->
      stop_client(client)
      stop_process(transport)
    end)

    active = submit(client, 0, 100)
    assert_receive {:serial_read, 1}, 200

    queued =
      for address <- 1..@serial_queued_requests do
        submit(client, address, 10 + rem(address, 20))
      end

    submissions = Map.new([active | queued])
    results = collect_results(submissions)

    assert map_size(results) == @serial_queued_requests + 1
    assert Enum.all?(results, fn {_reference, result} -> result == {:error, :timeout} end)
    refute_duplicate_result(submissions, 100)

    assert Client.status(client) == :connected
    assert DeadlineTransport.write_count(transport) == 1

    successful = submit(client, 100, 200)
    assert collect_results(Map.new([successful])) == %{elem(successful, 0) => {:ok, [42]}}
    refute_duplicate_result(Map.new([successful]), 25)
    assert DeadlineTransport.write_count(transport) == 2
  end

  test "TCP pending and queued requests report once by their deadline despite late responses" do
    handler = fn _unit_id, {:read_holding_registers, address, 1} ->
      case address do
        0 ->
          {:ok, [address]}

        1 ->
          {:error, {:exception, :illegal_data_address}}

        2 ->
          Process.sleep(300)
          {:ok, [address]}

        _address ->
          {:ok, [address]}
      end
    end

    {:ok, server} =
      TCPServer.start_link(handler,
        port: 0,
        address: {127, 0, 0, 1},
        handler_timeout: 1_000
      )

    {:ok, client} =
      Client.start_link(
        tcp: {127, 0, 0, 1},
        port: TCPServer.port(server),
        max_pending: 4
      )

    on_exit(fn ->
      stop_client(client)
      stop_server(server)
    end)

    assert eventually(fn -> Client.status(client) == :connected end)

    submissions =
      0..(@tcp_requests - 1)
      |> Enum.map(&submit(client, &1, 150))
      |> Map.new()

    results = collect_results(submissions)

    assert results[reference_for(submissions, 0)] == {:ok, [0]}

    assert results[reference_for(submissions, 1)] ==
             {:error, {:exception, :illegal_data_address}}

    assert results[reference_for(submissions, 2)] == {:error, :timeout}
    assert Enum.count(results, fn {_reference, result} -> result == {:error, :timeout} end) > 0

    Process.sleep(200)
    refute_duplicate_result(submissions, 50)
  end

  defp submit(client, address, timeout_ms) do
    started_at = monotonic_ms()

    reference =
      Client.send_request(
        client,
        1,
        {:read_holding_registers, address, 1},
        timeout: timeout_ms
      )

    {reference, %{address: address, started_at: started_at, timeout_ms: timeout_ms}}
  end

  defp collect_results(submissions), do: collect_results(submissions, %{})

  defp collect_results(submissions, results) when map_size(submissions) == map_size(results),
    do: results

  defp collect_results(submissions, results) do
    receive do
      {Client, reference, result} ->
        assert %{started_at: started_at, timeout_ms: timeout_ms} = submissions[reference]
        refute Map.has_key?(results, reference), "duplicate result for #{inspect(reference)}"

        elapsed_ms = monotonic_ms() - started_at

        assert elapsed_ms <= timeout_ms + @deadline_slack_ms,
               "result for #{inspect(reference)} exceeded its deadline: " <>
                 "#{elapsed_ms}ms > #{timeout_ms}ms + #{@deadline_slack_ms}ms slack"

        collect_results(submissions, Map.put(results, reference, result))
    after
      2_000 ->
        missing = Map.keys(submissions) -- Map.keys(results)
        flunk("missing results for #{inspect(missing)}")
    end
  end

  defp reference_for(submissions, address) do
    {reference, _metadata} =
      Enum.find(submissions, fn {_reference, metadata} -> metadata.address == address end)

    reference
  end

  defp refute_duplicate_result(submissions, timeout_ms) do
    receive do
      {Client, reference, result} ->
        if Map.has_key?(submissions, reference) do
          flunk("duplicate result for #{inspect(reference)}: #{inspect(result)}")
        else
          refute_duplicate_result(submissions, timeout_ms)
        end
    after
      timeout_ms -> :ok
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
    if Process.alive?(elem(server, 1)), do: TCPServer.stop(server)
  catch
    :exit, _reason -> :ok
  end

  defp stop_process(process) do
    if Process.alive?(process), do: Agent.stop(process)
  catch
    :exit, _reason -> :ok
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
