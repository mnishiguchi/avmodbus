defmodule AVModbus.TCPClientTest do
  use ExUnit.Case, async: true

  alias AVModbus.{Client, TCP}

  defp listen(port \\ 0) do
    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, selected_port}} = :inet.sockname(listener)
    {listener, selected_port}
  end

  defp accept(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    socket
  end

  defp start_client(port, options \\ [], host \\ {127, 0, 0, 1}) do
    {:ok, client} = Client.start_link([tcp: host, port: port] ++ options)

    on_exit(fn ->
      pid = elem(client, 1)
      if Process.alive?(pid), do: Client.close(client)
    end)

    client
  end

  defp next_frame(socket, timeout \\ 2_000) do
    with {:ok, <<transaction_id::16, 0::16, length::16>>} <-
           :gen_tcp.recv(socket, 6, timeout),
         {:ok, <<unit_id, pdu::binary>>} <- :gen_tcp.recv(socket, length, timeout) do
      {:ok, transaction_id, unit_id, pdu}
    end
  end

  defp answer(socket, transaction_id, unit_id, pdu) do
    {:ok, frame} = TCP.encode(transaction_id, unit_id, pdu)
    :gen_tcp.send(socket, frame)
  end

  defp results(references, results \\ [])
  defp results([], results), do: Enum.reverse(results)

  defp results([reference | rest], results) do
    assert_receive {Client, ^reference, result}, 2_000
    results(rest, [result | results])
  end

  test "keeps several requests in flight and matches out-of-order responses" do
    {listener, port} = listen()
    client = start_client(port, [max_pending: 2], "127.0.0.1")

    references =
      for address <- 0..3 do
        Client.send_request(client, 1, {:read_holding_registers, address, 1})
      end

    socket = accept(listener)
    first = for _index <- 1..2, do: next_frame(socket)
    assert :gen_tcp.recv(socket, 0, 50) == {:error, :timeout}

    for {:ok, transaction_id, unit_id, <<3, address::16, 1::16>>} <- Enum.reverse(first) do
      :ok = answer(socket, transaction_id, unit_id, <<3, 2, address + 100::16>>)
    end

    second = for _index <- 1..2, do: next_frame(socket)

    for {:ok, transaction_id, unit_id, <<3, address::16, 1::16>>} <- Enum.reverse(second) do
      :ok = answer(socket, transaction_id, unit_id, <<3, 2, address + 100::16>>)
    end

    assert results(references) == for(value <- 100..103, do: {:ok, [value]})

    transaction_ids =
      for {:ok, transaction_id, _unit_id, _pdu} <- first ++ second, do: transaction_id

    assert length(Enum.uniq(transaction_ids)) == 4
  end

  test "bounds its wait queue and accepts work again after saturation" do
    {listener, port} = listen()
    client = start_client(port, max_pending: 1, max_queue: 2)
    socket = accept(listener)
    assert eventually(fn -> Client.status(client) == :connected end)

    first = Client.send_request(client, 1, {:read_holding_registers, 0, 1}, 1_000)
    second = Client.send_request(client, 1, {:read_holding_registers, 1, 1}, 1_000)
    third = Client.send_request(client, 1, {:read_holding_registers, 2, 1}, 1_000)
    rejected = Client.send_request(client, 1, {:read_holding_registers, 3, 1}, 1_000)

    {:ok, first_transaction, 1, <<3, 0::16, 1::16>>} = next_frame(socket)
    assert_receive {Client, ^rejected, {:error, :queue_full}}, 500

    blocked =
      Task.async(fn -> Client.read_holding_registers(client, 1, 4, 1, 1_000) end)

    assert Task.await(blocked) == {:error, :queue_full}
    assert :gen_tcp.recv(socket, 0, 50) == {:error, :timeout}

    :ok = answer(socket, first_transaction, 1, <<3, 2, 10::16>>)
    {:ok, second_transaction, 1, <<3, 1::16, 1::16>>} = next_frame(socket)
    :ok = answer(socket, second_transaction, 1, <<3, 2, 11::16>>)
    {:ok, third_transaction, 1, <<3, 2::16, 1::16>>} = next_frame(socket)
    :ok = answer(socket, third_transaction, 1, <<3, 2, 12::16>>)

    assert results([first, second, third]) == [{:ok, [10]}, {:ok, [11]}, {:ok, [12]}]

    recovered = Client.send_request(client, 1, {:read_holding_registers, 5, 1}, 1_000)
    {:ok, recovered_transaction, 1, <<3, 5::16, 1::16>>} = next_frame(socket)
    :ok = answer(socket, recovered_transaction, 1, <<3, 2, 15::16>>)
    assert_receive {Client, ^recovered, {:ok, [15]}}, 500
  end

  test "allows direct sends with a zero-length wait queue" do
    {listener, port} = listen()
    client = start_client(port, max_pending: 1, max_queue: 0)
    socket = accept(listener)
    assert eventually(fn -> Client.status(client) == :connected end)

    accepted = Client.send_request(client, 1, {:read_coils, 0, 1}, 1_000)
    rejected = Client.send_request(client, 1, {:read_coils, 1, 1}, 1_000)
    {:ok, transaction_id, 1, <<1, 0::16, 1::16>>} = next_frame(socket)

    assert_receive {Client, ^rejected, {:error, :queue_full}}, 500
    :ok = answer(socket, transaction_id, 1, <<1, 1, 1>>)
    assert_receive {Client, ^accepted, {:ok, [true]}}, 500
  end

  test "handles fragmented input, foreign protocols, and concatenated frames" do
    {listener, port} = listen()
    client = start_client(port, max_pending: 2)
    first_ref = Client.send_request(client, 1, {:read_coils, 0, 1})
    second_ref = Client.send_request(client, 1, {:read_coils, 1, 1})
    socket = accept(listener)

    {:ok, first_transaction, 1, _pdu} = next_frame(socket)
    {:ok, second_transaction, 1, _pdu} = next_frame(socket)
    foreign = <<9::16, 7::16, 3::16, 1, 2, 3>>
    {:ok, first_answer} = TCP.encode(first_transaction, 1, <<1, 1, 1>>)
    {:ok, second_answer} = TCP.encode(second_transaction, 1, <<1, 1, 0>>)
    <<head::binary-size(5), tail::binary>> = first_answer

    :ok = :gen_tcp.send(socket, foreign <> head)
    :ok = :gen_tcp.send(socket, tail <> second_answer)

    assert results([first_ref, second_ref]) == [{:ok, [true]}, {:ok, [false]}]
  end

  test "connects to IPv6 literal hosts as text or tuples" do
    address = {0, 0, 0, 0, 0, 0, 0, 1}

    {:ok, listener} =
      :gen_tcp.listen(0, [:inet6, :binary, active: false, reuseaddr: true, ip: address])

    {:ok, {^address, port}} = :inet.sockname(listener)

    for host <- ["::1", address] do
      client = start_client(port, [], host)
      task = Task.async(fn -> Client.read_coils(client, 1, 0, 1, 500) end)
      socket = accept(listener)
      {:ok, transaction_id, unit_id, _pdu} = next_frame(socket)
      :ok = answer(socket, transaction_id, unit_id, <<1, 1, 1>>)
      assert Task.await(task) == {:ok, [true]}
      :ok = Client.stop(client)
    end

    :ok = :gen_tcp.close(listener)
  end

  test "accepts per-request keyword options over TCP" do
    {listener, port} = listen()
    client = start_client(port)

    task =
      Task.async(fn ->
        Client.read_holding_registers(client, 1, 4, 1, timeout: 500)
      end)

    socket = accept(listener)
    {:ok, transaction_id, unit_id, <<3, 4::16, 1::16>>} = next_frame(socket)
    :ok = answer(socket, transaction_id, unit_id, <<3, 2, 42::16>>)
    assert Task.await(task) == {:ok, [42]}
  end

  test "uses the TCP client default timeout unless a request overrides it" do
    {listener, port} = listen()
    client = start_client(port, timeout: 20)
    socket = accept(listener)

    defaulted = Task.async(fn -> Client.read_holding_registers(client, 1, 4, 1) end)
    assert {:ok, _transaction_id, 1, <<3, 4::16, 1::16>>} = next_frame(socket)
    assert Task.await(defaulted, 500) == {:error, :timeout}

    overridden =
      Task.async(fn ->
        Client.read_holding_registers(client, 1, 5, 1, timeout: 500)
      end)

    {:ok, transaction_id, unit_id, <<3, 5::16, 1::16>>} = next_frame(socket)
    :ok = answer(socket, transaction_id, unit_id, <<3, 2, 42::16>>)
    assert Task.await(overridden) == {:ok, [42]}
  end

  test "checks response units unless explicitly disabled" do
    {listener, port} = listen()
    client = start_client(port)
    task = Task.async(fn -> Client.read_coils(client, 3, 0, 1, 500) end)
    socket = accept(listener)
    {:ok, transaction_id, 3, _pdu} = next_frame(socket)
    :ok = answer(socket, transaction_id, 5, <<1, 1, 1>>)
    assert Task.await(task) == {:error, {:invalid_response, <<1, 1, 1>>}}

    {other_listener, other_port} = listen()
    unchecked = start_client(other_port, check_unit: false)
    other_task = Task.async(fn -> Client.read_coils(unchecked, 3, 0, 1, 500) end)
    other_socket = accept(other_listener)
    {:ok, other_transaction, 3, _pdu} = next_frame(other_socket)
    :ok = answer(other_socket, other_transaction, 255, <<1, 1, 1>>)
    assert Task.await(other_task) == {:ok, [true]}
  end

  test "drops late responses without confusing the next transaction" do
    {listener, port} = listen()
    client = start_client(port, max_pending: 1)
    socket = accept(listener)
    slow = Client.send_request(client, 1, {:read_coils, 0, 1}, 50)
    next = Client.send_request(client, 1, {:read_coils, 1, 1}, 500)
    {:ok, slow_transaction, 1, _pdu} = next_frame(socket)

    assert_receive {Client, ^slow, {:error, :timeout}}, 500
    {:ok, next_transaction, 1, _pdu} = next_frame(socket)
    refute next_transaction == slow_transaction
    {:ok, late} = TCP.encode(slow_transaction, 1, <<1, 1, 1>>)
    {:ok, current} = TCP.encode(next_transaction, 1, <<1, 1, 0>>)
    :ok = :gen_tcp.send(socket, late <> current)
    assert_receive {Client, ^next, {:ok, [false]}}, 500
    refute_received {Client, ^slow, _result}
  end

  test "resets a connection after two silent request timeouts" do
    {listener, port} = listen()
    client = start_client(port, max_pending: 1, backoff: {10, 10})
    socket = accept(listener)

    for _index <- 1..2 do
      task = Task.async(fn -> Client.read_coils(client, 1, 0, 1, 50) end)
      assert {:ok, _transaction_id, 1, _pdu} = next_frame(socket)
      assert Task.await(task) == {:error, :timeout}
    end

    assert :gen_tcp.recv(socket, 0, 500) == {:error, :closed}
    next_socket = accept(listener)
    assert eventually(fn -> Client.status(client) == :connected end)
    task = Task.async(fn -> Client.read_coils(client, 1, 0, 1, 500) end)
    {:ok, transaction_id, unit_id, _pdu} = next_frame(next_socket)
    :ok = answer(next_socket, transaction_id, unit_id, <<1, 1, 0>>)
    assert Task.await(task) == {:ok, [false]}
  end

  test "closes an invalid stream and reconnects" do
    {listener, port} = listen()
    client = start_client(port, backoff: {10, 10})
    first = Client.send_request(client, 1, {:read_coils, 0, 1}, 500)
    socket = accept(listener)
    {:ok, transaction_id, 1, _pdu} = next_frame(socket)
    :ok = :gen_tcp.send(socket, <<transaction_id::16, 0::16, 60_000::16, 1>>)

    assert_receive {Client, ^first, {:error, :closed}}, 500
    assert :gen_tcp.recv(socket, 0, 500) == {:error, :closed}

    next_socket = accept(listener)
    assert eventually(fn -> Client.status(client) == :connected end)
    task = Task.async(fn -> Client.read_coils(client, 1, 0, 1, 500) end)
    {:ok, next_transaction, unit_id, _pdu} = next_frame(next_socket)
    :ok = answer(next_socket, next_transaction, unit_id, <<1, 1, 1>>)
    assert Task.await(task) == {:ok, [true]}
  end

  test "fails pending and queued requests once after a peer half-close, then reconnects" do
    {listener, port} = listen()
    client = start_client(port, max_pending: 1, backoff: {10, 10})
    first = Client.send_request(client, 1, {:read_coils, 0, 1}, 500)
    second = Client.send_request(client, 1, {:read_coils, 1, 1}, 500)
    socket = accept(listener)

    assert {:ok, _transaction_id, 1, <<1, 0::16, 1::16>>} = next_frame(socket)
    assert :gen_tcp.recv(socket, 0, 50) == {:error, :timeout}
    :ok = :gen_tcp.shutdown(socket, :write)

    assert_receive {Client, ^first, {:error, :closed}}, 500
    assert_receive {Client, ^second, {:error, :closed}}, 500
    refute_receive {Client, ^first, _result}, 50
    refute_receive {Client, ^second, _result}, 50
    assert :gen_tcp.recv(socket, 0, 500) == {:error, :closed}

    next_socket = accept(listener)
    assert eventually(fn -> Client.status(client) == :connected end)
    task = Task.async(fn -> Client.read_coils(client, 1, 2, 1, 500) end)
    {:ok, transaction_id, unit_id, <<1, 2::16, 1::16>>} = next_frame(next_socket)
    :ok = answer(next_socket, transaction_id, unit_id, <<1, 1, 1>>)
    assert Task.await(task) == {:ok, [true]}
  end

  test "fails an in-flight request after a peer reset, then reconnects" do
    {listener, port} = listen()
    client = start_client(port, backoff: {10, 10})
    reference = Client.send_request(client, 1, {:read_coils, 0, 1}, 500)
    socket = accept(listener)

    assert {:ok, _transaction_id, 1, <<1, 0::16, 1::16>>} = next_frame(socket)
    :ok = :inet.setopts(socket, linger: {true, 0})
    :ok = :gen_tcp.close(socket)

    assert_receive {Client, ^reference, {:error, :closed}}, 500
    refute_receive {Client, ^reference, _result}, 50

    next_socket = accept(listener)
    assert eventually(fn -> Client.status(client) == :connected end)
    task = Task.async(fn -> Client.read_coils(client, 1, 1, 1, 500) end)
    {:ok, transaction_id, unit_id, <<1, 1::16, 1::16>>} = next_frame(next_socket)
    :ok = answer(next_socket, transaction_id, unit_id, <<1, 1, 0>>)
    assert Task.await(task) == {:ok, [false]}
  end

  test "reports failed connections, fails requests promptly, and keeps retrying" do
    {listener, port} = listen()
    :ok = :gen_tcp.close(listener)
    client = start_client(port, backoff: {20, 20})
    assert eventually(fn -> match?({:disconnected, _reason}, Client.status(client)) end)
    assert Client.read_coils(client, 1, 0, 1, 100) == {:error, :closed}

    {next_listener, ^port} = listen(port)
    socket = accept(next_listener)
    assert eventually(fn -> Client.status(client) == :connected end)
    task = Task.async(fn -> Client.read_coils(client, 255, 0, 1, 500) end)
    {:ok, transaction_id, 255, _pdu} = next_frame(socket)
    :ok = answer(socket, transaction_id, 255, <<1, 1, 1>>)
    assert Task.await(task) == {:ok, [true]}
  end

  test "validates TCP client options" do
    assert Client.start_link(tcp: :invalid) == {:error, :invalid_tcp_host}
    assert Client.start_link(tcp: {127, 0, 0}) == {:error, :invalid_tcp_host}
    assert Client.start_link(tcp: {127, 0, 0, 1}, port: 0) == {:error, :invalid_port_option}

    assert Client.start_link(tcp: {127, 0, 0, 1}, max_pending: 0) ==
             {:error, :invalid_max_pending_option}

    assert Client.start_link(tcp: {127, 0, 0, 1}, max_queue: -1) ==
             {:error, :invalid_max_queue_option}

    assert Client.start_link(tcp: {127, 0, 0, 1}, check_unit: :no) ==
             {:error, :invalid_check_unit_option}

    assert Client.start_link(tcp: {127, 0, 0, 1}, connect_timeout: 0) ==
             {:error, :invalid_connect_timeout_option}

    assert Client.start_link(tcp: {127, 0, 0, 1}, timeout: 0) ==
             {:error, :invalid_timeout_option}

    assert Client.start_link(tcp: {127, 0, 0, 1}, echo: true) ==
             {:error, {:invalid_option, {:echo, true}}}
  end

  test "a synchronous caller gets closed when the client is gone" do
    {listener, port} = listen()
    client = start_client(port)
    _socket = accept(listener)
    pid = elem(client, 1)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    assert eventually(fn -> not Process.alive?(pid) end)
    assert Client.read_coils(client, 1, 0, 1, 100) == {:error, :closed}
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
