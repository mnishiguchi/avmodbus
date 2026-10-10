defmodule AVModbus.TCPFDExhaustionProbe do
  alias AVModbus.Client
  alias AVModbus.Server.TCP, as: TCPServer

  def run([port_text]) do
    port = String.to_integer(port_text)
    warm_up(port)
    {exhaustion_reason, sockets} = exhaust([])

    unless exhaustion_reason in [:emfile, :enfile, :system_limit] do
      fail({:unexpected_exhaustion_reason, exhaustion_reason})
    end

    {:ok, client} =
      Client.start_link(
        tcp: {127, 0, 0, 1},
        port: port,
        connect_timeout: 200,
        backoff: {20, 20},
        timeout: 1_000
      )

    disconnected =
      await_status(client, fn
        {:disconnected, reason} when reason in [:emfile, :enfile, :system_limit] -> true
        _status -> false
      end)

    sockets = release(sockets, 8)
    :connected = await_status(client, &(&1 == :connected))
    {:ok, [42]} = Client.read_holding_registers(client, 1, 0, 1)
    :ok = Client.stop(client)

    {server_exhaustion_reason, sockets} = exhaust(sockets)

    unless server_exhaustion_reason in [:emfile, :enfile, :system_limit] do
      fail({:unexpected_server_exhaustion_reason, server_exhaustion_reason})
    end

    handler = handler()
    {:error, ^server_exhaustion_reason} = TCPServer.start_link(handler, port: 0)
    sockets = release(sockets, 8)
    {:ok, server} = TCPServer.start_link(handler, port: 0)
    {:listening, 0} = TCPServer.status(server)
    :ok = TCPServer.stop(server)
    [] = release(sockets, length(sockets))

    IO.puts(
      "fd_probe result=ok client_exhausted=#{inspect(exhaustion_reason)} " <>
        "client_status=#{inspect(disconnected)} server_exhausted=#{inspect(server_exhaustion_reason)}"
    )
  end

  defp warm_up(port) do
    {:ok, client} =
      Client.start_link(
        tcp: {127, 0, 0, 1},
        port: port,
        connect_timeout: 200,
        backoff: {20, 20},
        timeout: 1_000
      )

    :connected = await_status(client, &(&1 == :connected))
    {:ok, [42]} = Client.read_holding_registers(client, 1, 0, 1)
    :ok = Client.stop(client)

    {:ok, server} = TCPServer.start_link(handler(), port: 0)
    {:listening, 0} = TCPServer.status(server)
    :ok = TCPServer.stop(server)
  end

  defp handler do
    fn _unit_id, {:read_holding_registers, 0, 1} -> {:ok, [42]} end
  end

  defp exhaust(sockets) do
    case :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}]) do
      {:ok, socket} -> exhaust([socket | sockets])
      {:error, reason} -> {reason, sockets}
    end
  end

  defp release(sockets, 0), do: sockets
  defp release([], _remaining), do: []

  defp release([socket | sockets], remaining) do
    :ok = :gen_tcp.close(socket)
    release(sockets, remaining - 1)
  end

  defp await_status(client, predicate, attempts \\ 200)
  defp await_status(_client, _predicate, 0), do: fail(:status_timeout)

  defp await_status(client, predicate, attempts) do
    status = Client.status(client)

    if predicate.(status) do
      status
    else
      Process.sleep(10)
      await_status(client, predicate, attempts - 1)
    end
  end

  defp fail(reason) do
    IO.puts("fd_probe result=error reason=#{inspect(reason)}")
    System.halt(1)
  end
end

AVModbus.TCPFDExhaustionProbe.run(System.argv())
