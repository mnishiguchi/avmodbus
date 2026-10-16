defmodule DisterlProbe.Distributed do
  @moduledoc """
  Genuine distributed Erlang experiment over the Modbus virtual UART.
  """

  @compile {:no_warn_undefined, :net_kernel}

  @role Application.compile_env(:disterl_probe, :role, :client)
  @serial Application.compile_env(:disterl_probe, :serial, [])
  @unit_id Application.compile_env(:disterl_probe, :unit_id, 1)
  @timeout_ms Application.compile_env(:disterl_probe, :timeout_ms, 500)
  @poll_ms Application.compile_env(:disterl_probe, :poll_ms, 20)
  @trace_transactions Application.compile_env(:disterl_probe, :trace_transactions, false)
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
          poll_ms: @poll_ms,
          trace_transactions: @trace_transactions
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
