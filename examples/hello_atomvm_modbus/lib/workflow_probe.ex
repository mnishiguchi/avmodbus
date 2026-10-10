if Application.compile_env(:sample_app, :workflow_probe, false) do
  defmodule SampleApp.WorkflowTransport do
    @moduledoc false

    alias AVModbus.UART

    def write({uart, observer}, data) do
      send(observer, {:workflow_transport, :write, monotonic_ms()})
      UART.write(uart, data)
    end

    def read({uart, observer}, timeout_ms) do
      result = UART.read(uart, timeout_ms)

      case result do
        {:ok, data} when is_binary(data) and data != <<>> ->
          send(observer, {:workflow_transport, :read, monotonic_ms()})

        _other ->
          :ok
      end

      result
    end

    def close(_uart), do: :ok

    defp monotonic_ms, do: :erlang.monotonic_time(:millisecond)
  end

  defmodule SampleApp.WorkflowProbe do
    @moduledoc false

    alias AVModbus.{Client, RTU, UART}
    alias SampleApp.WorkflowTransport

    @cycles Application.compile_env(:sample_app, :workflow_probe_cycles, 3)
    @unit_id Application.compile_env(:sample_app, :modbus_unit_id, 1)
    @timeout_ms Application.compile_env(:sample_app, :modbus_response_timeout_ms, 1_000)
    @speed Application.compile_env(:avmodbus, :uart_speed, 9_600)
    @turnaround_ms Application.compile_env(:avmodbus, :modbus_broadcast_turnaround_ms, 100)
    @configured_gap_ms Application.compile_env(:sample_app, :workflow_probe_gap_ms, 20)
    @calculated_gap_ms div(RTU.frame_gap_us(@speed) + 999, 1_000)
    @gap_ms if(@configured_gap_ms > 0, do: @configured_gap_ms, else: @calculated_gap_ms)
    @echo_test_value 0xA55A
    @identification %{0 => "AVModbus", 1 => "Seeed Studio XIAO ESP32-C5", 2 => "0.1.0"}

    @steps [
      {:write_single_register, {:request, @unit_id, {:write_single_register, 10, 0x1234}}, :ok},
      {:read_single_register, {:request, @unit_id, {:read_holding_registers, 10, 1}},
       {:ok, [0x1234]}},
      {:mask_write_register, {:request, @unit_id, {:mask_write_register, 10, 0xFF00, 0x0056}},
       :ok},
      {:read_masked_register, {:request, @unit_id, {:read_holding_registers, 10, 1}},
       {:ok, [0x1256]}},
      {:write_multiple_registers,
       {:request, @unit_id, {:write_multiple_registers, 20, [1, 2, 0xFFFF]}}, :ok},
      {:read_multiple_registers, {:request, @unit_id, {:read_holding_registers, 20, 3}},
       {:ok, [1, 2, 0xFFFF]}},
      {:read_write_multiple_registers,
       {:request, @unit_id, {:read_write_multiple_registers, 30, 3, 30, [7, 8]}},
       {:ok, [7, 8, 0]}},
      {:write_single_coil, {:request, @unit_id, {:write_single_coil, 0, true}}, :ok},
      {:read_single_coil, {:request, @unit_id, {:read_coils, 0, 1}}, {:ok, [true]}},
      {:write_multiple_coils,
       {:request, @unit_id, {:write_multiple_coils, 10, [true, false, true, true]}}, :ok},
      {:read_multiple_coils, {:request, @unit_id, {:read_coils, 10, 4}},
       {:ok, [true, false, true, true]}},
      {:write_file_record,
       {:request, @unit_id, {:write_file_record, [{1, 50, [0x1111, 0x2222]}]}}, :ok},
      {:read_file_record, {:request, @unit_id, {:read_file_record, [{1, 50, 2}]}},
       {:ok, [[0x1111, 0x2222]]}},
      {:prepare_fifo, {:request, @unit_id, {:write_multiple_registers, 50, [2, 31, 32]}}, :ok},
      {:read_fifo, {:request, @unit_id, {:read_fifo_queue, 50}}, {:ok, [31, 32]}},
      {:diagnostics_echo, {:request, @unit_id, {:diagnostics, 0, [0xA537]}}, {:ok, [0xA537]}},
      {:device_identification, :device_identification, {:ok, @identification}},
      {:broadcast_write, {:request, 0, {:write_single_register, 40, 0x4242}}, :ok},
      {:read_broadcast_value, {:request, @unit_id, {:read_holding_registers, 40, 1}},
       {:ok, [0x4242]}},
      {:exception_response, {:request, @unit_id, :read_exception_status},
       {:error, {:exception, :illegal_function}}}
    ]

    def start do
      Process.sleep(100)

      result =
        with {:ok, echo} <- classify_echo(),
             {:ok, stats} <- run_workflow(),
             :ok <- validate_timing(stats) do
          report_success(echo, stats)
          :ok
        end

      case result do
        :ok -> :ok
        {:error, reason} -> IO.puts("modbus_workflow result=error reason=#{inspect(reason)}")
      end

      Process.sleep(:infinity)
    end

    defp classify_echo do
      with {:ok, uart} <- UART.open() do
        result = classify_echo(uart)
        UART.close(uart)
        flush_transport_events()
        result
      end
    end

    defp classify_echo(uart) do
      with {:ok, client} <-
             Client.start_link(WorkflowTransport, {uart, self()},
               echo: true,
               gap: @gap_ms,
               timeout: 250
             ) do
        write = Client.write_single_register(client, @unit_id, 90, @echo_test_value)
        read = Client.read_holding_registers(client, @unit_id, 90, 1)
        Client.stop(client)

        case {write, read} do
          {:ok, {:ok, [@echo_test_value]}} -> {:ok, :present}
          {{:error, :timeout}, {:ok, [@echo_test_value]}} -> {:ok, :absent}
          other -> {:error, {:echo_classification, other}}
        end
      end
    end

    defp run_workflow do
      with {:ok, uart} <- UART.open() do
        result = run_workflow(uart)
        UART.close(uart)
        result
      end
    end

    defp run_workflow(uart) do
      with {:ok, client} <-
             Client.start_link(WorkflowTransport, {uart, self()},
               echo: false,
               gap: @gap_ms,
               turnaround: @turnaround_ms,
               timeout: @timeout_ms
             ) do
        result = run_cycles(client, 1, empty_stats())
        Client.stop(client)
        result
      end
    end

    defp run_cycles(_client, cycle, stats) when cycle > @cycles, do: {:ok, stats}

    defp run_cycles(client, cycle, stats) do
      case run_steps(client, cycle, @steps, stats) do
        {:ok, next} -> run_cycles(client, cycle + 1, next)
        {:error, _reason} = error -> error
      end
    end

    defp run_steps(_client, _cycle, [], stats), do: {:ok, stats}

    defp run_steps(client, cycle, [{label, operation, expected} | steps], stats) do
      started_at = monotonic_ms()
      result = invoke(client, operation)
      elapsed_ms = monotonic_ms() - started_at
      next = record_step(drain_transport_events(stats), label, elapsed_ms)

      IO.puts(
        "modbus_workflow cycle=#{cycle} step=#{label} elapsed_ms=#{elapsed_ms} result=#{inspect(result)}"
      )

      if result == expected do
        run_steps(client, cycle, steps, next)
      else
        report_partial_timing(next)
        {:error, {:unexpected_result, cycle, label, expected, result}}
      end
    end

    defp invoke(client, {:request, unit_id, request}),
      do: Client.request(client, unit_id, request, @timeout_ms)

    defp invoke(client, :device_identification),
      do: Client.read_device_identification(client, @unit_id, :basic, @timeout_ms)

    defp empty_stats do
      %{
        requests: 0,
        total_ms: 0,
        min_request_ms: nil,
        max_request_ms: nil,
        last_read_ms: nil,
        min_gap_ms: nil,
        broadcast_ms: nil
      }
    end

    defp record_step(stats, label, elapsed_ms) do
      %{
        stats
        | requests: stats.requests + 1,
          total_ms: stats.total_ms + elapsed_ms,
          min_request_ms: smaller(stats.min_request_ms, elapsed_ms),
          max_request_ms: larger(stats.max_request_ms, elapsed_ms),
          broadcast_ms: if(label == :broadcast_write, do: elapsed_ms, else: stats.broadcast_ms)
      }
    end

    defp drain_transport_events(stats) do
      receive do
        {:workflow_transport, :read, at_ms} ->
          drain_transport_events(%{stats | last_read_ms: at_ms})

        {:workflow_transport, :write, at_ms} ->
          gap_ms =
            case stats.last_read_ms do
              nil -> stats.min_gap_ms
              last_read_ms -> smaller(stats.min_gap_ms, at_ms - last_read_ms)
            end

          drain_transport_events(%{stats | min_gap_ms: gap_ms})
      after
        0 -> stats
      end
    end

    defp flush_transport_events do
      receive do
        {:workflow_transport, _operation, _at_ms} -> flush_transport_events()
      after
        0 -> :ok
      end
    end

    defp validate_timing(stats) do
      cond do
        is_nil(stats.min_gap_ms) ->
          {:error, :frame_gap_not_observed}

        is_nil(stats.broadcast_ms) ->
          {:error, :broadcast_turnaround_not_observed}

        stats.min_gap_ms < @gap_ms ->
          {:error, {:frame_gap_too_short, @gap_ms, stats.min_gap_ms}}

        stats.broadcast_ms < @turnaround_ms ->
          {:error, {:broadcast_turnaround_too_short, @turnaround_ms, stats.broadcast_ms}}

        true ->
          :ok
      end
    end

    defp report_partial_timing(stats) do
      IO.puts(
        "modbus_workflow timing=partial requests=#{stats.requests} " <>
          "gap_configured_ms=#{@gap_ms} gap_observed_min_ms=#{stats.min_gap_ms} " <>
          "turnaround_observed_ms=#{stats.broadcast_ms}"
      )
    end

    defp report_success(echo, stats) do
      IO.puts(
        "modbus_workflow result=ok cycles=#{@cycles} requests=#{stats.requests} " <>
          "echo=#{echo} speed=#{@speed} gap_calculated_ms=#{@calculated_gap_ms} " <>
          "gap_configured_ms=#{@gap_ms} " <>
          "gap_observed_min_ms=#{stats.min_gap_ms} turnaround_required_ms=#{@turnaround_ms} " <>
          "turnaround_observed_ms=#{stats.broadcast_ms} request_min_ms=#{stats.min_request_ms} " <>
          "request_max_ms=#{stats.max_request_ms} total_ms=#{stats.total_ms}"
      )
    end

    defp smaller(nil, value), do: value
    defp smaller(left, right) when left <= right, do: left
    defp smaller(_left, right), do: right

    defp larger(nil, value), do: value
    defp larger(left, right) when left >= right, do: left
    defp larger(_left, right), do: right

    defp monotonic_ms, do: :erlang.monotonic_time(:millisecond)
  end
end
