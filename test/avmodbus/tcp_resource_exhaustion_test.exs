defmodule AVModbus.TCPResourceExhaustionTest do
  use ExUnit.Case, async: false

  @moduletag :resource_exhaustion

  test "client and server recover after the OS file descriptor limit is released" do
    assert :os.type() == {:unix, :linux}

    listener_options = [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]
    {:ok, listener} = :gen_tcp.listen(0, listener_options)
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    server = Task.async(fn -> serve_requests(listener, 2) end)
    ebin = Application.app_dir(:avmodbus, "ebin")
    probe = Path.expand("../support/tcp_fd_exhaustion_probe.exs", __DIR__)
    elixir = System.find_executable("elixir")

    command = ~S(ulimit -n 64; exec "$1" -pa "$2" "$3" "$4")

    {output, exit_status} =
      System.cmd(
        "bash",
        [
          "-c",
          command,
          "avmodbus-fd-probe",
          elixir,
          ebin,
          probe,
          Integer.to_string(port)
        ],
        stderr_to_stdout: true
      )

    assert exit_status == 0, output
    assert output =~ "fd_probe result=ok"
    assert output =~ "client_exhausted=:emfile"
    assert output =~ "client_status={:disconnected, :emfile}"
    assert output =~ "server_exhausted=:emfile"
    assert [:ok, :ok] == Task.await(server, 6_000)
  end

  defp serve_requests(_listener, 0), do: []

  defp serve_requests(listener, remaining) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    {:ok, <<transaction_id::16, 0::16, length::16>>} = :gen_tcp.recv(socket, 6, 2_000)
    {:ok, <<unit_id, 3, 0::16, 1::16>>} = :gen_tcp.recv(socket, length, 2_000)
    :ok = :gen_tcp.send(socket, <<transaction_id::16, 0::16, 5::16, unit_id, 3, 2, 42::16>>)
    :ok = :gen_tcp.close(socket)
    [:ok | serve_requests(listener, remaining - 1)]
  end
end
