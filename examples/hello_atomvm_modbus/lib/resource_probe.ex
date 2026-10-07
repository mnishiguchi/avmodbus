if Application.compile_env(:sample_app, :resource_probe, false) do
  defmodule SampleApp.ResourceProbe do
    @moduledoc false

    alias AVModbus.Client
    alias AVModbus.Server.TCP, as: TCPServer

    @cycles Application.compile_env(:sample_app, :resource_probe_cycles, 3)
    @connections Application.compile_env(:sample_app, :resource_probe_connections, 4)
    @requests_per_client 4
    @handler_delay_ms 100
    @request_timeout_ms 2_000
    @heap_recovery_slack 32_768

    def start do
      Process.sleep(100)

      result =
        with :ok <- warm_up() do
          run_cycles(1)
        end

      case result do
        :ok ->
          IO.puts("modbus_resource_probe result=ok cycles=#{@cycles}")

        {:error, reason} ->
          IO.puts("modbus_resource_probe result=error reason=#{inspect(reason)}")
      end

      Process.sleep(:infinity)
    end

    defp warm_up, do: run_cycle("warmup", snapshot(), false)

    defp run_cycles(cycle) when cycle > @cycles, do: :ok

    defp run_cycles(cycle) do
      before = snapshot()

      case run_cycle(cycle, before, true) do
        :ok -> run_cycles(cycle + 1)
        {:error, _reason} = error -> error
      end
    end

    defp run_cycle(cycle, before, check_heap) do
      handler = fn _unit_id, {:read_holding_registers, address, 1} ->
        Process.sleep(@handler_delay_ms)
        {:ok, [address]}
      end

      with {:ok, server} <-
             TCPServer.start_link(handler,
               address: {127, 0, 0, 1},
               port: 0,
               connections: @connections,
               handler_timeout: @request_timeout_ms
             ) do
        run_with_server(cycle, before, check_heap, server)
      else
        {:error, _reason} = error -> error
      end
    end

    defp run_with_server(cycle, before, check_heap, server) do
      case start_clients(TCPServer.port(server), @connections, []) do
        {:ok, clients} ->
          run_with_clients(cycle, before, check_heap, server, clients)

        {:error, reason, clients} ->
          stop_resources(clients, server)
          {:error, reason}
      end
    end

    defp run_with_clients(cycle, before, check_heap, server, clients) do
      result =
        with :ok <- await_connected(clients, 200),
             expected = submit_requests(clients, 1, []),
             peak = snapshot(),
             :ok <- collect_results(expected, @request_timeout_ms + 1_000) do
          {:ok, peak}
        end

      stop_resources(clients, server)
      {recovery, after_cleanup} = await_recovery(before, check_heap, 50)

      case result do
        {:ok, peak} ->
          report(cycle, before, peak, after_cleanup)

          if recovery == :ok do
            :ok
          else
            {:error,
             {:resources_not_recovered, before.process_count, after_cleanup.process_count,
              before.free_heap, after_cleanup.free_heap}}
          end

        {:error, _reason} = error ->
          error
      end
    end

    defp await_recovery(before, check_heap, attempts) do
      true = :erlang.garbage_collect()
      current = snapshot()

      cond do
        recovered?(before, current, check_heap) ->
          {:ok, current}

        attempts == 0 ->
          {:error, current}

        true ->
          Process.sleep(100)
          await_recovery(before, check_heap, attempts - 1)
      end
    end

    defp start_clients(_port, 0, clients), do: {:ok, Enum.reverse(clients)}

    defp start_clients(port, remaining, clients) do
      case Client.start_link(
             tcp: {127, 0, 0, 1},
             port: port,
             max_pending: 1,
             max_queue: @requests_per_client - 2,
             timeout: @request_timeout_ms,
             backoff: {20, 100}
           ) do
        {:ok, client} -> start_clients(port, remaining - 1, [client | clients])
        {:error, reason} -> {:error, {:client_start, reason}, clients}
      end
    end

    defp await_connected(_clients, 0), do: {:error, :connect_timeout}

    defp await_connected(clients, attempts) do
      if Enum.all?(clients, fn client -> Client.status(client) == :connected end) do
        :ok
      else
        Process.sleep(10)
        await_connected(clients, attempts - 1)
      end
    end

    defp submit_requests([], _client_index, expected), do: expected

    defp submit_requests([client | clients], client_index, expected) do
      expected = submit_client_requests(client, client_index, 0, expected)
      submit_requests(clients, client_index + 1, expected)
    end

    defp submit_client_requests(_client, _client_index, @requests_per_client, expected),
      do: expected

    defp submit_client_requests(client, client_index, request_index, expected) do
      address = client_index * 100 + request_index

      reference =
        Client.send_request(client, client_index, {:read_holding_registers, address, 1})

      result = if request_index < 3, do: {:ok, [address]}, else: {:error, :queue_full}

      submit_client_requests(
        client,
        client_index,
        request_index + 1,
        [{reference, result} | expected]
      )
    end

    defp collect_results([], _timeout_ms), do: :ok

    defp collect_results(expected, timeout_ms) do
      receive do
        {Client, reference, result} ->
          case take_expected(expected, reference, []) do
            {:ok, ^result, remaining} -> collect_results(remaining, timeout_ms)
            :error -> {:error, {:unexpected_result, reference, result}}
            {:ok, wanted, _remaining} -> {:error, {:wrong_result, reference, wanted, result}}
          end
      after
        timeout_ms -> {:error, {:missing_results, length(expected)}}
      end
    end

    defp take_expected([], _reference, _before), do: :error

    defp take_expected([{reference, result} | expected], reference, before) do
      {:ok, result, reverse_append(before, expected)}
    end

    defp take_expected([entry | expected], reference, before) do
      take_expected(expected, reference, [entry | before])
    end

    defp reverse_append([], tail), do: tail
    defp reverse_append([head | rest], tail), do: reverse_append(rest, [head | tail])

    defp stop_resources(clients, server) do
      Enum.each(clients, fn client -> Client.stop(client) end)
      TCPServer.stop(server)
    end

    defp snapshot do
      %{
        free_heap: :erlang.system_info(:esp32_free_heap_size),
        largest_free_block: :erlang.system_info(:esp32_largest_free_block),
        process_count: :erlang.system_info(:process_count)
      }
    end

    defp recovered?(before, after_cleanup, check_heap) do
      processes_recovered = after_cleanup.process_count <= before.process_count + 1

      heap_recovered =
        not check_heap or after_cleanup.free_heap + @heap_recovery_slack >= before.free_heap

      processes_recovered and heap_recovered
    end

    defp report(cycle, before, peak, after_cleanup) do
      IO.puts(
        "modbus_resource_probe cycle=#{cycle} " <>
          "processes=#{before.process_count}/#{peak.process_count}/#{after_cleanup.process_count} " <>
          "free_heap=#{before.free_heap}/#{peak.free_heap}/#{after_cleanup.free_heap} " <>
          "largest_free=#{before.largest_free_block}/#{peak.largest_free_block}/#{after_cleanup.largest_free_block}"
      )
    end
  end
end
