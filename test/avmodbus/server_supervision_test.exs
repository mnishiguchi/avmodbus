defmodule AVModbus.ServerSupervisionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AVModbus.Server.ASCII, as: ASCIIServer
  alias AVModbus.Server.RTU, as: RTUServer
  alias AVModbus.Server.TCP, as: TCPServer

  @tcp_name __MODULE__.TCPServer
  @rtu_name __MODULE__.RTUServer
  @ascii_name __MODULE__.ASCIIServer

  defmodule FakeTransport do
    def read(_uart, timeout_ms) do
      Process.sleep(timeout_ms)
      {:error, :timeout}
    end

    def write(_uart, _data), do: :ok
    def close(_uart), do: :ok
  end

  test "TCP server runs under a supervisor and accepts its raw pid or registered name" do
    handler = fn _unit_id, _request -> {:error, {:exception, :illegal_function}} end

    server =
      start_supervised!(
        {TCPServer,
         [
           handler: handler,
           port: 0,
           address: {127, 0, 0, 1},
           name: @tcp_name
         ]},
        id: make_ref()
      )

    assert Process.whereis(@tcp_name) == server
    assert TCPServer.port(server) == TCPServer.port(@tcp_name)
    assert TCPServer.status(server) == {:listening, 0}

    capture_log(fn ->
      Process.exit(server, :kill)

      assert eventually(fn ->
               case Process.whereis(@tcp_name) do
                 replacement when is_pid(replacement) -> replacement != server
                 _other -> false
               end
             end)
    end)

    assert TCPServer.status(@tcp_name) == {:listening, 0}
  end

  test "serial servers accept raw pids and registered names" do
    handler = fn _unit_id, _request -> {:error, {:exception, :illegal_function}} end

    {:ok, {RTUServer, rtu}} =
      RTUServer.start_link(FakeTransport, :rtu_uart, handler,
        units: [1],
        silence: 1,
        name: @rtu_name
      )

    assert Process.whereis(@rtu_name) == rtu
    assert RTUServer.status(rtu) == :connected
    assert RTUServer.status(@rtu_name) == :connected
    assert RTUServer.stop(@rtu_name) == :ok
    refute Process.alive?(rtu)

    {:ok, {ASCIIServer, ascii}} =
      ASCIIServer.start_link(FakeTransport, :ascii_uart, handler,
        units: [1],
        silence: 1,
        name: @ascii_name
      )

    assert Process.whereis(@ascii_name) == ascii
    assert ASCIIServer.status(ascii) == :connected
    assert ASCIIServer.status(@ascii_name) == :connected
    assert ASCIIServer.stop(@ascii_name) == :ok
    refute Process.alive?(ascii)
  end

  test "server child specs require handlers and reject invalid names" do
    handler = fn _unit_id, _request -> :ok end

    assert TCPServer.child_spec(handler: handler, name: @tcp_name).id == @tcp_name
    assert RTUServer.child_spec(handler: handler, units: [1], name: @rtu_name).id == @rtu_name

    assert ASCIIServer.child_spec(handler: handler, units: [1], name: @ascii_name).id ==
             @ascii_name

    assert TCPServer.start_supervised(port: 0) == {:error, :missing_handler_option}

    assert TCPServer.start_link(handler, name: "invalid") ==
             {:error, :invalid_name_option}

    assert RTUServer.start_link(handler, units: [1], name: "invalid") ==
             {:error, :invalid_name_option}

    assert ASCIIServer.start_link(handler, units: [1], name: "invalid") ==
             {:error, :invalid_name_option}
  end

  defp eventually(function, attempts \\ 100)
  defp eventually(_function, 0), do: false

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end
end
