defmodule DisterlProbe.Distributed do
  @moduledoc """
  Genuine distributed Erlang experiment over the Modbus virtual UART.
  """

  @compile {:no_warn_undefined, :net_kernel}

  @role Application.compile_env(:disterl_probe, :role, :client)
  @serial Application.compile_env(:disterl_probe, :serial, [])
  @unit_id Application.compile_env(:disterl_probe, :unit_id, 1)
  @timeout_ms Application.compile_env(:disterl_probe, :timeout_ms, 500)
  @bulk_timeout_ms Application.compile_env(:disterl_probe, :bulk_timeout_ms, 2_000)
  @chunk_payload_bytes Application.compile_env(:disterl_probe, :chunk_payload_bytes, 96)
  @max_queued_bytes Application.compile_env(:disterl_probe, :max_queued_bytes, 8_192)
  @max_queued_chunks Application.compile_env(:disterl_probe, :max_queued_chunks, 256)
  @fault_drop_responses Application.compile_env(:disterl_probe, :fault_drop_responses, 0)
  @fault_min_payload_bytes Application.compile_env(
                             :disterl_probe,
                             :fault_min_payload_bytes,
                             96
                           )
  @fault_after_ms Application.compile_env(:disterl_probe, :fault_after_ms, 10_000)
  @poll_ms Application.compile_env(:disterl_probe, :poll_ms, 20)
  @trace_transactions Application.compile_env(:disterl_probe, :trace_transactions, false)
  @trace_queue Application.compile_env(:disterl_probe, :trace_queue, false)
  @node_alias Application.compile_env(:disterl_probe, :node_alias, "a")
  @peer_alias Application.compile_env(:disterl_probe, :peer_alias, "b")
  @cookie Application.compile_env(:disterl_probe, :cookie, "AtomVM")

  def start do
    identity = identity()
    started_at = :erlang.monotonic_time(:millisecond)

    case :net_kernel.start(identity.node, dist_options()) do
      {:ok, _pid} ->
        :ok = :net_kernel.set_cookie(@cookie)
        log_started(identity)
        {:ok, _demo} = DisterlProbe.PingPong.start_link(identity, started_at)
        Process.sleep(:infinity)

      other ->
        IO.puts("modbus_disterl: net_kernel start failed #{inspect(other)}")
        Process.sleep(:infinity)
    end
  end

  defp identity do
    %{
      role: @role,
      node: :"#{@node_alias}@modbus.local",
      peer: :"#{@peer_alias}@modbus.local"
    }
  end

  defp dist_options do
    %{
      name_domain: :longnames,
      proto_dist: :serial_dist,
      avm_dist_opts: %{
        uart_opts: [
          role: @role,
          serial: @serial,
          unit_id: @unit_id,
          timeout_ms: @timeout_ms,
          bulk_timeout_ms: @bulk_timeout_ms,
          chunk_payload_bytes: @chunk_payload_bytes,
          max_queued_bytes: @max_queued_bytes,
          max_queued_chunks: @max_queued_chunks,
          fault_drop_responses: @fault_drop_responses,
          fault_min_payload_bytes: @fault_min_payload_bytes,
          fault_after_ms: @fault_after_ms,
          poll_ms: @poll_ms,
          trace_transactions: @trace_transactions,
          trace_queue: @trace_queue
        ],
        uart_module: DisterlProbe.ModbusUART
      }
    }
  end

  defp log_started(identity) do
    IO.puts("modbus_disterl: node #{inspect(identity.node)}")
    IO.puts("modbus_disterl: peer #{inspect(identity.peer)}")
    IO.puts("modbus_disterl: cookie configured")
    IO.puts("modbus_disterl: virtual UART over FC 100 ready")
  end
end
