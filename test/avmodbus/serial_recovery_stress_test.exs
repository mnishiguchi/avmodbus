defmodule AVModbus.SerialRecoveryStressTest do
  use ExUnit.Case, async: false

  alias AVModbus.{Client, RTU}

  @failures_per_cycle 12
  @cycles 3

  defmodule ReopeningTransport do
    def start_link(open_results) do
      Agent.start_link(
        fn ->
          %{
            open_results: open_results,
            open_count: 0,
            reads: [],
            writes: 0,
            closes: 0
          }
        end,
        name: __MODULE__
      )
    end

    def open do
      Agent.get_and_update(__MODULE__, fn
        %{open_results: [result | rest]} = state ->
          {result, %{state | open_results: rest, open_count: state.open_count + 1}}

        state ->
          {{:error, :unexpected_open}, %{state | open_count: state.open_count + 1}}
      end)
    end

    def write(_uart, _data) do
      Agent.update(__MODULE__, fn state -> %{state | writes: state.writes + 1} end)
    end

    def read(_uart, timeout_ms) do
      result =
        Agent.get_and_update(__MODULE__, fn
          %{reads: [result | rest]} = state -> {result, %{state | reads: rest}}
          state -> {nil, state}
        end)

      if result do
        result
      else
        Process.sleep(timeout_ms)
        {:error, :timeout}
      end
    end

    def close(_uart) do
      Agent.update(__MODULE__, fn state -> %{state | closes: state.closes + 1} end)
    end

    def push(result) do
      Agent.update(__MODULE__, fn state -> %{state | reads: state.reads ++ [result]} end)
    end

    def snapshot, do: Agent.get(__MODULE__, & &1)
  end

  test "remains usable across repeated timeouts, CRC errors, and UART reconnects" do
    open_results = for index <- 1..@cycles, do: {:ok, {:uart, index}}
    {:ok, transport_state} = ReopeningTransport.start_link(open_results)

    {:ok, client} =
      Client.start_link(ReopeningTransport,
        gap: 0,
        silence: 1,
        backoff: {1, 1}
      )

    on_exit(fn ->
      stop_client(client)
      stop_agent(transport_state)
    end)

    {:ok, valid_response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    bad_crc_response = corrupt_crc(valid_response)

    for cycle <- 1..@cycles do
      assert Client.status(client) == :connected

      for attempt <- 1..@failures_per_cycle do
        if rem(attempt, 2) == 1,
          do: ReopeningTransport.push({:ok, bad_crc_response})

        reference =
          Client.send_request(client, 1, {:read_holding_registers, attempt, 1}, timeout: 10)

        assert_receive {Client, ^reference, {:error, :timeout}}, 500
        refute_receive {Client, ^reference, _duplicate}, 5
      end

      if cycle < @cycles do
        ReopeningTransport.push({:error, {:uart_disconnected, cycle}})

        reference =
          Client.send_request(client, 1, {:read_holding_registers, 0, 1}, timeout: 100)

        assert_receive {Client, ^reference, {:error, :closed}}, 500
        refute_receive {Client, ^reference, _duplicate}, 5
        assert wait_until(fn -> ReopeningTransport.snapshot().open_count == cycle + 1 end)
        assert wait_until(fn -> Client.status(client) == :connected end)
      end
    end

    ReopeningTransport.push({:ok, valid_response})
    final = Client.send_request(client, 1, {:read_holding_registers, 0, 1}, timeout: 100)
    assert_receive {Client, ^final, {:ok, [42]}}, 500
    refute_receive {Client, ^final, _duplicate}, 5

    expected_writes = @cycles * @failures_per_cycle + (@cycles - 1) + 1

    assert %{
             open_count: @cycles,
             closes: closes,
             writes: ^expected_writes,
             reads: []
           } = ReopeningTransport.snapshot()

    assert closes == @cycles - 1
    assert Process.alive?(elem(client, 1))
  end

  defp corrupt_crc(frame) do
    size = byte_size(frame)
    <<prefix::binary-size(size - 1), last>> = frame
    <<prefix::binary, Bitwise.bxor(last, 0x01)>>
  end

  defp wait_until(function, attempts \\ 200)
  defp wait_until(_function, 0), do: false

  defp wait_until(function, attempts) do
    if function.() do
      true
    else
      Process.sleep(5)
      wait_until(function, attempts - 1)
    end
  end

  defp stop_client(client) do
    if Process.alive?(elem(client, 1)), do: Client.close(client)
  catch
    :exit, _reason -> :ok
  end

  defp stop_agent(agent) do
    if Process.alive?(agent), do: Agent.stop(agent)
  catch
    :exit, _reason -> :ok
  end
end
