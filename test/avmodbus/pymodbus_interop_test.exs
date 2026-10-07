defmodule AVModbus.PymodbusInteropTest do
  use ExUnit.Case, async: false

  alias AVModbus.{Client, Memory}
  alias AVModbus.Server.ASCII, as: ASCIIServer
  alias AVModbus.Server.RTU, as: RTUServer
  alias AVModbus.Server.TCP, as: TCPServer
  alias AVModbus.Test.PTYTransport

  @moduletag :interop
  @peer Path.expand("../support/pymodbus_peer.py", __DIR__)

  @expected [
    "write_registers ok ",
    "read_holding_registers ok 1 2 3",
    "write_register ok ",
    "mask_write_register ok ",
    "read_holding_registers ok 23",
    "write_coils ok ",
    "read_coils ok 1 0 1 0 0 0 0 0",
    "write_coil ok ",
    "read_coils ok 1 0 0 0 0 0 0 0",
    "readwrite_registers ok 7 8",
    "read_input_registers ok 0 0",
    "read_discrete_inputs ok 0 0 0 0 0 0 0 0",
    "read_holding_registers exception 2"
  ]
  @extension_expected ["custom ok 3 2 1", "mei ok 5 4"]

  defp python, do: System.fetch_env!("PYMODBUS_PYTHON")

  defp start_peer_server(target, transport \\ :tcp, role \\ "server") do
    port =
      Port.open({:spawn_executable, python()}, [
        :binary,
        :stderr_to_stdout,
        args: [@peer, role, Atom.to_string(transport), to_string(target)]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
      System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    case await_ready(port, "") do
      :ok -> {:ok, port}
      {:error, _reason} = error -> error
    end
  end

  defp await_ready(port, output) do
    if String.contains?(output, "ready") do
      :ok
    else
      receive do
        {^port, {:data, data}} -> await_ready(port, output <> data)
      after
        10_000 -> flunk("pymodbus server did not start: #{output}")
      end
    end
  end

  defp run_peer_client(target, transport \\ :tcp, role \\ "client") do
    {output, 0} =
      System.cmd(
        python(),
        [@peer, role, Atom.to_string(transport), to_string(target)],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n")
    |> Enum.filter(&(String.contains?(&1, " ok") or String.contains?(&1, " exception")))
  end

  defp check_extension_client(client, timeout_ms \\ 1_000) do
    assert Client.custom(client, 1, 0x41, <<1, 2, 3>>, timeout_ms) == {:ok, <<3, 2, 1>>}

    assert Client.encapsulated_interface_transport(client, 1, 0x0D, <<4, 5>>, timeout_ms) ==
             {:ok, <<5, 4>>}
  end

  defp extension_handler(1, {:custom, 0x41, <<1, 2, 3>>}), do: {:ok, <<3, 2, 1>>}

  defp extension_handler(1, {:encapsulated_interface_transport, 0x0D, <<4, 5>>}),
    do: {:ok, <<5, 4>>}

  defp extension_handler(_unit_id, _request), do: {:error, :illegal_function}

  defp free_port do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    port
  end

  defp check_client(client, timeout_ms \\ 1_000, peer_port \\ nil) do
    result = Client.read_holding_registers(client, 1, 0, 3, timeout_ms)
    assert_peer_result(result, {:ok, [1000, 1001, 1002]}, peer_port)

    assert Client.read_input_registers(client, 1, 98, 2, timeout_ms) == {:ok, [2098, 2099]}
    assert Client.read_coils(client, 1, 0, 4, timeout_ms) == {:ok, [true, false, false, true]}
    assert Client.write_multiple_registers(client, 1, 50, [5, 6], timeout_ms) == :ok
    assert Client.read_holding_registers(client, 1, 50, 2, timeout_ms) == {:ok, [5, 6]}
    assert Client.write_single_coil(client, 1, 1, true, timeout_ms) == :ok
    assert Client.read_coils(client, 1, 1, 1, timeout_ms) == {:ok, [true]}
    assert Client.mask_write_register(client, 1, 60, 0xFF00, 0x0012, timeout_ms) == :ok

    assert Client.read_write_multiple_registers(client, 1, 70, 2, 70, [9, 10], timeout_ms) ==
             {:ok, [9, 10]}

    assert Client.read_holding_registers(client, 1, 999, 1, timeout_ms) ==
             {:error, {:exception, :illegal_data_address}}

    assert Client.read_device_identification(client, 1, :basic, timeout_ms) ==
             {:ok, %{0 => "pymodbus", 1 => "PM", 2 => "3.15"}}
  end

  test "AVModbus client interoperates with a pymodbus server" do
    port = free_port()
    {:ok, _peer_port} = start_peer_server(port)
    {:ok, client} = Client.start_link(tcp: {127, 0, 0, 1}, port: port)
    on_exit(fn -> if Process.alive?(elem(client, 1)), do: Client.close(client) end)
    check_client(client)
  end

  test "pymodbus client interoperates with an AVModbus server" do
    {:ok, memory} = Memory.start_link(holding_registers: 1_000, coils: 100)
    on_exit(fn -> if Process.alive?(memory), do: GenServer.stop(memory) end)

    {:ok, server} =
      TCPServer.start_link({Memory, memory}, port: 0, address: {127, 0, 0, 1})

    on_exit(fn -> if Process.alive?(elem(server, 1)), do: TCPServer.close(server) end)
    assert run_peer_client(TCPServer.port(server)) == @expected
  end

  test "AVModbus client interoperates with pymodbus custom function and MEI extensions" do
    port = free_port()
    {:ok, _peer_port} = start_peer_server(port, :tcp, "extension-server")
    {:ok, client} = Client.start_link(tcp: {127, 0, 0, 1}, port: port)
    on_exit(fn -> if Process.alive?(elem(client, 1)), do: Client.close(client) end)
    check_extension_client(client)
  end

  test "pymodbus custom function and MEI extensions interoperate with an AVModbus server" do
    {:ok, server} =
      TCPServer.start_link(&extension_handler/2, port: 0, address: {127, 0, 0, 1})

    on_exit(fn -> if Process.alive?(elem(server, 1)), do: TCPServer.close(server) end)

    assert run_peer_client(TCPServer.port(server), :tcp, "extension-client") ==
             @extension_expected
  end

  for transport <- [:rtu, :ascii] do
    test "AVModbus #{transport} client interoperates with a pymodbus server" do
      transport_mode = unquote(transport)
      {:ok, pty} = PTYTransport.start_link(python())
      {:ok, peer_port} = start_peer_server(PTYTransport.path(pty), transport_mode)
      {:ok, client} = Client.start_link(PTYTransport, pty, mode: transport_mode, gap: 0)

      on_exit(fn ->
        if Process.alive?(elem(client, 1)), do: Client.close(client)
        if Process.alive?(pty), do: PTYTransport.close(pty)
      end)

      check_client(client, 3_000, peer_port)
    end

    test "pymodbus #{transport} client interoperates with an AVModbus server" do
      transport_mode = unquote(transport)
      {:ok, pty} = PTYTransport.start_link(python())
      {:ok, memory} = Memory.start_link(holding_registers: 1_000, coils: 100)
      server_module = unquote(if(transport == :rtu, do: RTUServer, else: ASCIIServer))

      {:ok, server} =
        server_module.start_link(PTYTransport, pty, {Memory, memory}, units: [1], gap: 0)

      on_exit(fn ->
        if Process.alive?(elem(server, 1)), do: server_module.close(server)
        if Process.alive?(memory), do: GenServer.stop(memory)
        if Process.alive?(pty), do: PTYTransport.close(pty)
      end)

      assert run_peer_client(PTYTransport.path(pty), transport_mode) == @expected
    end

    test "AVModbus #{transport} client interoperates with pymodbus custom function and MEI extensions" do
      transport_mode = unquote(transport)
      {:ok, pty} = PTYTransport.start_link(python())

      {:ok, _peer_port} =
        start_peer_server(PTYTransport.path(pty), transport_mode, "extension-server")

      {:ok, client} = Client.start_link(PTYTransport, pty, mode: transport_mode, gap: 0)

      on_exit(fn ->
        if Process.alive?(elem(client, 1)), do: Client.close(client)
        if Process.alive?(pty), do: PTYTransport.close(pty)
      end)

      check_extension_client(client, 3_000)
    end

    test "pymodbus #{transport} custom function and MEI extensions interoperate with an AVModbus server" do
      transport_mode = unquote(transport)
      {:ok, pty} = PTYTransport.start_link(python())
      server_module = unquote(if(transport == :rtu, do: RTUServer, else: ASCIIServer))

      {:ok, server} =
        server_module.start_link(PTYTransport, pty, &extension_handler/2, units: [1], gap: 0)

      on_exit(fn ->
        if Process.alive?(elem(server, 1)), do: server_module.close(server)
        if Process.alive?(pty), do: PTYTransport.close(pty)
      end)

      assert run_peer_client(PTYTransport.path(pty), transport_mode, "extension-client") ==
               @extension_expected
    end
  end

  defp peer_output(port, output \\ "") do
    receive do
      {^port, {:data, data}} -> peer_output(port, output <> data)
      {^port, {:exit_status, status}} -> output <> "exit status #{status}"
    after
      100 -> output
    end
  end

  defp assert_peer_result(result, expected, nil), do: assert(result == expected)

  defp assert_peer_result(result, expected, port) do
    if result != expected do
      flunk(
        "expected #{inspect(expected)}, got #{inspect(result)}; " <>
          "pymodbus server output: #{inspect(peer_output(port))}"
      )
    end
  end
end
