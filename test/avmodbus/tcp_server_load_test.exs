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
            tcp: {127, 0, 0, 1},
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
    if Process.alive?(elem(server, 1)), do: TCPServer.stop(server)
  catch
    :exit, _reason -> :ok
  end
end
