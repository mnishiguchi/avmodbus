defmodule AVModbus.ServerFacadeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AVModbus.{Client, Memory, Server}
  alias AVModbus.Server.TCP, as: TCPServer

  @server_name __MODULE__.ManagedServer
  @direct_name __MODULE__.DirectServer

  test "routes to TCP by default and runs under a supervisor" do
    memory = start_supervised!({Memory, holding_registers: 10}, id: make_ref())

    server =
      start_supervised!(
        {Server,
         [
           handler: {Memory, memory},
           port: 0,
           address: {127, 0, 0, 1},
           name: @server_name
         ]},
        id: make_ref()
      )

    assert Process.whereis(@server_name) == server
    assert Server.status(server) == {:listening, 0}
    port = Server.port(@server_name)

    {:ok, client} = Client.start_link(tcp: {127, 0, 0, 1}, port: port)
    on_exit(fn -> if Process.alive?(elem(client, 1)), do: Client.stop(client) end)

    assert Client.write_single_register(client, 1, 3, 42, 500) == :ok
    assert Client.read_holding_registers(client, 1, 3, 1, 500) == {:ok, [42]}

    capture_log(fn ->
      Process.exit(server, :kill)

      assert eventually(fn ->
               case Process.whereis(@server_name) do
                 replacement when is_pid(replacement) -> replacement != server
                 _other -> false
               end
             end)
    end)

    assert Server.status(@server_name) == {:listening, 0}
  end

  test "accepts explicit TCP selection and transport tagged handles" do
    handler = fn _unit_id, _request -> {:error, {:exception, :illegal_function}} end

    {:ok, direct} =
      Server.start_link(
        handler: handler,
        tcp: true,
        port: 0,
        address: {127, 0, 0, 1},
        name: @direct_name
      )

    assert Process.whereis(@direct_name) == direct
    assert is_integer(Server.port(@direct_name))
    assert Server.stop(@direct_name) == :ok

    {:ok, tagged} =
      TCPServer.start_link(handler, port: 0, address: {127, 0, 0, 1})

    assert Server.status(tagged) == {:listening, 0}
    assert is_integer(Server.port(tagged))
    assert Server.close(tagged) == :ok
  end

  test "validates unified transport selection" do
    handler = fn _unit_id, _request -> :ok end

    assert Server.start_link(:invalid) == {:error, :invalid_options}
    assert Server.start_link(port: 0) == {:error, :missing_handler_option}

    assert Server.start_link(handler: handler, transport: :udp) ==
             {:error, :invalid_transport_option}

    assert Server.start_link(handler: handler, transport: :tls) ==
             {:error, :tls_not_supported}

    assert Server.start_link(handler: handler, ssl: []) == {:error, :tls_not_supported}
    assert Server.start_link(handler: handler, tls: true) == {:error, :tls_not_supported}

    assert Server.start_link(handler: handler, rtu: false) ==
             {:error, :invalid_rtu_option}

    assert Server.start_link(handler: handler, rtu: true, ascii: true) ==
             {:error, :multiple_transport_options}

    assert Server.start_link(handler: handler, transport: :tcp, tcp: true) ==
             {:error, :multiple_transport_options}

    assert Server.start_link(handler: handler, tcp: true, unknown: 1) ==
             {:error, {:invalid_option, {:unknown, 1}}}
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
