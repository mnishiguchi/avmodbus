defmodule AVModbus.ClientRetryTest do
  use ExUnit.Case, async: true

  alias AVModbus.{Client, RTU, TCP}

  defmodule RetryTransport do
    def start_link(results) do
      Agent.start_link(fn -> %{results: results, writes: 0} end)
    end

    def write(transport, _data) do
      Agent.update(transport, fn state -> %{state | writes: state.writes + 1} end)
    end

    def read(transport, _timeout_ms) do
      Agent.get_and_update(transport, fn
        %{results: [result | rest]} = state -> {result, %{state | results: rest}}
        state -> {{:error, :timeout}, state}
      end)
    end

    def close(_transport), do: :ok
    def write_count(transport), do: Agent.get(transport, & &1.writes)
  end

  test "retries an idempotent read after a transient timeout" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {transport, client} = start_client([{:error, :timeout}, {:ok, response}])

    assert Client.retry_request(client, 1, {:read_holding_registers, 0, 1},
             timeout: 20,
             retries: 1,
             backoff: {1, 1}
           ) == {:ok, [42]}

    assert RetryTransport.write_count(transport) == 2
  end

  test "accepts retry options through the regular request helpers" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {transport, client} = start_client([{:error, :timeout}, {:ok, response}])

    assert Client.read_holding_registers(client, 1, 0, 1,
             timeout: 20,
             retries: 1,
             backoff: {1, 1}
           ) == {:ok, [42]}

    assert RetryTransport.write_count(transport) == 2
  end

  test "does not retry unless request options explicitly ask for it" do
    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    {transport, client} = start_client([{:error, :timeout}, {:ok, response}])

    assert Client.request(client, 1, {:read_holding_registers, 0, 1}, timeout: 20) ==
             {:error, :timeout}

    assert RetryTransport.write_count(transport) == 1
  end

  test "retries an idempotent read after a TCP reconnect" do
    {listener, port} = listen()

    {:ok, client} =
      Client.start_link(tcp: {127, 0, 0, 1}, port: port, backoff: {5, 5})

    on_exit(fn ->
      client_pid = elem(client, 1)
      if Process.alive?(client_pid), do: Client.stop(client)
    end)

    first_socket = accept(listener)

    task =
      Task.async(fn ->
        Client.read_holding_registers(client, 1, 0, 1,
          timeout: 200,
          retries: 1,
          backoff: {30, 30}
        )
      end)

    {:ok, _transaction, _unit, _request} = next_frame(first_socket)
    :ok = :gen_tcp.close(first_socket)

    second_socket = accept(listener)
    {:ok, transaction, unit, _request} = next_frame(second_socket)
    {:ok, response} = TCP.encode(transaction, unit, <<0x03, 0x02, 0x00, 0x2A>>)
    :ok = :gen_tcp.send(second_socket, response)

    assert Task.await(task, 1_000) == {:ok, [42]}
  end

  test "never retries a write request" do
    {transport, client} = start_client([{:error, :timeout}])

    assert Client.retry_request(client, 1, {:write_single_register, 0, 42},
             retries: 3,
             backoff: {1, 1}
           ) == {:error, :retry_requires_idempotent_read}

    assert RetryTransport.write_count(transport) == 0
  end

  test "regular write helpers reject replay options before sending" do
    {transport, client} = start_client([])

    assert Client.write_single_register(client, 1, 0, 42,
             retries: 1,
             backoff: {1, 1}
           ) == {:error, :retry_requires_idempotent_read}

    assert RetryTransport.write_count(transport) == 0
  end

  test "returns Modbus exceptions without retrying" do
    {:ok, response} = RTU.encode(1, <<0x83, 0x06>>)
    {transport, client} = start_client([{:ok, response}])

    assert Client.retry_request(client, 1, {:read_holding_registers, 0, 1},
             retries: 3,
             backoff: {1, 1}
           ) == {:error, {:exception, :server_device_busy}}

    assert RetryTransport.write_count(transport) == 1
  end

  test "validates retry options before sending" do
    {transport, client} = start_client([])
    request = {:read_holding_registers, 0, 1}

    assert Client.retry_request(client, 1, request, :invalid) == {:error, :invalid_options}

    assert Client.retry_request(client, 1, request, attempts: 2) ==
             {:error, {:invalid_option, {:attempts, 2}}}

    assert Client.retry_request(client, 1, request, timeout: -1) ==
             {:error, :invalid_timeout_option}

    assert Client.retry_request(client, 1, request, retries: -1) ==
             {:error, :invalid_retries_option}

    assert Client.retry_request(client, 1, request, backoff: {10, 5}) ==
             {:error, :invalid_backoff_option}

    assert RetryTransport.write_count(transport) == 0
  end

  test "validates regular request options before sending" do
    {transport, client} = start_client([])
    request = {:read_holding_registers, 0, 1}

    assert Client.request(client, 1, request, timeout: -1) ==
             {:error, :invalid_timeout_option}

    assert Client.request(client, 1, request, retries: -1) ==
             {:error, :invalid_retries_option}

    assert Client.request(client, 1, request, to: self()) ==
             {:error, {:invalid_option, {:to, self()}}}

    assert RetryTransport.write_count(transport) == 0
  end

  defp start_client(results) do
    {:ok, transport} = RetryTransport.start_link(results)
    {:ok, client} = Client.start_link(RetryTransport, transport, gap: 0, silence: 1)

    on_exit(fn ->
      client_pid = elem(client, 1)
      if Process.alive?(client_pid), do: Client.stop(client)
      if Process.alive?(transport), do: Agent.stop(transport)
    end)

    {transport, client}
  end

  defp listen do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, port}
  end

  defp accept(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 1_000)
    socket
  end

  defp next_frame(socket) do
    with {:ok, <<transaction::16, 0::16, length::16>>} <- :gen_tcp.recv(socket, 6, 1_000),
         {:ok, <<unit, pdu::binary>>} <- :gen_tcp.recv(socket, length, 1_000) do
      {:ok, transaction, unit, pdu}
    end
  end
end
