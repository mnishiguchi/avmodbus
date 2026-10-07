defmodule AVModbus.LibmodbusInteropTest do
  use ExUnit.Case, async: false

  alias AVModbus.{Client, Memory}
  alias AVModbus.Server.RTU, as: RTUServer
  alias AVModbus.Server.TCP, as: TCPServer
  alias AVModbus.Test.PTYTransport

  @moduletag :libmodbus
  @source Path.expand("../support/libmodbus_peer.c", __DIR__)

  @expected [
    "write_registers ok",
    "read_registers ok 1 2 3",
    "write_register ok",
    "mask_write_register ok",
    "read_registers ok 23",
    "write_bits ok",
    "read_bits ok 1 0 1",
    "write_bit ok",
    "read_bits ok 1",
    "write_and_read_registers ok 7 8",
    "read_input_registers ok 0 0",
    "read_input_bits ok 0 0",
    "read_registers error Illegal data address"
  ]

  setup_all do
    peer = Path.join(Mix.Project.build_path(), "libmodbus_peer")
    python = System.find_executable("python3") || flunk("python3 is required for RTU PTY tests")
    {flags, 0} = System.cmd("pkg-config", ["--cflags", "--libs", "libmodbus"])

    {output, status} =
      System.cmd(
        "cc",
        ["-std=c11", "-Wall", "-Wextra", "-Werror", "-o", peer, @source] ++
          String.split(flags),
        stderr_to_stdout: true
      )

    if status != 0, do: flunk("could not build libmodbus peer: #{output}")
    %{peer: peer, python: python}
  end

  test "AVModbus client interoperates with a libmodbus server", %{peer: peer} do
    port = free_port()
    {:ok, _peer_port} = start_peer_server(peer, port)
    {:ok, client} = Client.start_link(tcp: {127, 0, 0, 1}, port: port)
    on_exit(fn -> if Process.alive?(elem(client, 1)), do: Client.stop(client) end)

    check_client(client)
  end

  test "libmodbus client interoperates with an AVModbus server", %{peer: peer} do
    memory = start_supervised!({Memory, holding_registers: 1_000, coils: 100}, id: make_ref())

    server =
      start_supervised!(
        {TCPServer,
         [
           handler: {Memory, memory},
           port: 0,
           address: {127, 0, 0, 1}
         ]},
        id: make_ref()
      )

    assert run_peer_client(peer, TCPServer.port(server)) == @expected
  end

  test "AVModbus RTU client interoperates with a libmodbus server", %{
    peer: peer,
    python: python
  } do
    {:ok, pty} = PTYTransport.start_link(python)
    {:ok, peer_port} = start_peer_server(peer, PTYTransport.path(pty), :rtu)
    {:ok, client} = Client.start_link(PTYTransport, pty, mode: :rtu, gap: 0)

    on_exit(fn ->
      if Process.alive?(elem(client, 1)), do: Client.stop(client)
      if Process.alive?(pty), do: PTYTransport.close(pty)
    end)

    check_client(client, 3_000, peer_port)
  end

  test "libmodbus RTU client interoperates with an AVModbus server", %{
    peer: peer,
    python: python
  } do
    {:ok, pty} = PTYTransport.start_link(python)
    {:ok, memory} = Memory.start_link(holding_registers: 1_000, coils: 100)

    {:ok, server} =
      RTUServer.start_link(PTYTransport, pty, {Memory, memory}, units: [1], gap: 0)

    on_exit(fn ->
      if Process.alive?(elem(server, 1)), do: RTUServer.close(server)
      if Process.alive?(memory), do: GenServer.stop(memory)
      if Process.alive?(pty), do: PTYTransport.close(pty)
    end)

    assert run_peer_client(peer, PTYTransport.path(pty), :rtu) == @expected
    assert RTUServer.status(server) == :connected
  end

  defp check_client(client, timeout_ms \\ 1_000, peer_port \\ nil) do
    result = Client.read_holding_registers(client, 1, 0, 3, timeout_ms)
    assert_peer_result(result, {:ok, [1000, 1001, 1002]}, peer_port)

    assert Client.read_input_registers(client, 1, 98, 2, timeout_ms) == {:ok, [2098, 2099]}
    assert Client.read_coils(client, 1, 0, 4, timeout_ms) == {:ok, [true, false, false, true]}

    assert Client.read_discrete_inputs(client, 1, 0, 4, timeout_ms) ==
             {:ok, [true, false, true, false]}

    assert Client.write_multiple_registers(client, 1, 50, [5, 6], timeout_ms) == :ok
    assert Client.read_holding_registers(client, 1, 50, 2, timeout_ms) == {:ok, [5, 6]}
    assert Client.write_single_coil(client, 1, 1, true, timeout_ms) == :ok
    assert Client.write_multiple_coils(client, 1, 10, [true, true, false], timeout_ms) == :ok
    assert Client.read_coils(client, 1, 10, 3, timeout_ms) == {:ok, [true, true, false]}
    assert Client.mask_write_register(client, 1, 5, 0xF2, 0x25, timeout_ms) == :ok
    assert Client.read_holding_registers(client, 1, 5, 1, timeout_ms) == {:ok, [0xE5]}

    assert Client.read_write_multiple_registers(client, 1, 70, 2, 70, [9, 10], timeout_ms) ==
             {:ok, [9, 10]}

    assert Client.read_holding_registers(client, 1, 99, 2, timeout_ms) ==
             {:error, {:exception, :illegal_data_address}}

    assert {:ok, <<_id, 0xFF, "LMB", _version::binary>>} =
             Client.request(client, 1, :report_server_id, timeout_ms)
  end

  defp start_peer_server(peer, target, transport \\ :tcp) do
    port =
      Port.open({:spawn_executable, peer}, [
        :binary,
        :stderr_to_stdout,
        args: ["server", Atom.to_string(transport), to_string(target)]
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
        5_000 -> flunk("libmodbus server did not start: #{output}")
      end
    end
  end

  defp run_peer_client(peer, target, transport \\ :tcp) do
    {output, 0} =
      System.cmd(
        peer,
        ["client", Atom.to_string(transport), to_string(target)],
        stderr_to_stdout: true
      )

    String.split(output, "\n", trim: true)
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
          "libmodbus server output: #{inspect(peer_output(port))}"
      )
    end
  end

  defp free_port do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    port
  end
end
