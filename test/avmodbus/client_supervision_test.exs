defmodule AVModbus.ClientSupervisionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AVModbus.{Client, TCP}

  @client_name __MODULE__.ManagedClient
  @stopped_name __MODULE__.StoppedClient

  test "runs under a supervisor and accepts its raw pid or registered name" do
    {listener, port} = listen()

    client =
      start_supervised!(
        {Client,
         [
           tcp: {127, 0, 0, 1},
           port: port,
           name: @client_name,
           backoff: {10, 10}
         ]},
        id: make_ref()
      )

    assert is_pid(client)
    assert Process.whereis(@client_name) == client
    socket = accept(listener)
    assert eventually(fn -> Client.status(@client_name) == :connected end)

    task = Task.async(fn -> Client.read_coils(client, 1, 0, 1, 500) end)
    {:ok, transaction, unit, _request} = next_frame(socket)
    :ok = answer(socket, transaction, unit, <<0x01, 0x01, 0x01>>)
    assert Task.await(task) == {:ok, [true]}

    reference = Client.send_request(@client_name, 1, {:read_holding_registers, 4, 1}, 500)
    {:ok, transaction, unit, _request} = next_frame(socket)
    :ok = answer(socket, transaction, unit, <<0x03, 0x02, 0x00, 0x2A>>)
    assert_receive {Client, ^reference, {:ok, [42]}}, 500

    capture_log(fn ->
      Process.exit(client, :kill)

      assert eventually(fn ->
               case Process.whereis(@client_name) do
                 replacement when is_pid(replacement) -> replacement != client
                 _other -> false
               end
             end)
    end)

    _replacement_socket = accept(listener)
    assert eventually(fn -> Client.status(@client_name) == :connected end)
  end

  test "stop accepts a registered name and validates name options" do
    {listener, port} = listen()

    assert Client.start_link(tcp: {127, 0, 0, 1}, port: port, name: "invalid") ==
             {:error, :invalid_name_option}

    {:ok, {Client, client, :tcp}} =
      Client.start_link(tcp: {127, 0, 0, 1}, port: port, name: @stopped_name)

    _socket = accept(listener)
    assert Process.whereis(@stopped_name) == client
    assert Client.stop(@stopped_name) == :ok
    refute Process.alive?(client)
    assert Process.whereis(@stopped_name) == nil
  end

  defp listen do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, port}
  end

  defp accept(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    socket
  end

  defp next_frame(socket) do
    with {:ok, <<transaction::16, 0::16, length::16>>} <- :gen_tcp.recv(socket, 6, 1_000),
         {:ok, <<unit, pdu::binary>>} <- :gen_tcp.recv(socket, length, 1_000) do
      {:ok, transaction, unit, pdu}
    end
  end

  defp answer(socket, transaction, unit, pdu) do
    {:ok, frame} = TCP.encode(transaction, unit, pdu)
    :gen_tcp.send(socket, frame)
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
