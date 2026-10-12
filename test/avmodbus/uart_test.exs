defmodule AVModbus.UARTTest do
  use ExUnit.Case, async: false

  alias AVModbus.{Client, RTU, UART}

  defmodule FakeUART do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: __MODULE__)

    def open(_peripheral, _options) do
      case Process.whereis(__MODULE__) do
        nil -> {:error, :not_started}
        uart -> uart
      end
    end

    def read(uart, timeout_ms) do
      case GenServer.call(uart, {:read, timeout_ms}, timeout_ms + 100) do
        {:crash, reason} -> exit(reason)
        result -> result
      end
    end

    def write(uart, data) do
      GenServer.call(uart, {:write, data})
    end

    def close(uart) do
      GenServer.call(uart, :close)
    end

    def push(uart, result), do: GenServer.call(uart, {:push, result})

    @impl true
    def init(owner), do: {:ok, %{owner: owner, queued: [], waiter: nil}}

    @impl true
    def handle_call({:read, _timeout_ms}, _from, %{queued: [result | rest]} = state) do
      send(state.owner, {:uart_read, result})
      {:reply, result, %{state | queued: rest}}
    end

    def handle_call({:read, timeout_ms}, from, %{waiter: nil} = state) do
      send(state.owner, {:uart_waiting, elem(from, 0)})
      timer = Process.send_after(self(), {:read_timeout, from}, timeout_ms)
      {:noreply, %{state | waiter: {from, timer}}}
    end

    def handle_call({:push, result}, _from, %{waiter: {waiter, timer}} = state) do
      Process.cancel_timer(timer)
      GenServer.reply(waiter, result)
      send(state.owner, {:uart_read, result})
      {:reply, :ok, %{state | waiter: nil}}
    end

    def handle_call({:push, result}, _from, state) do
      {:reply, :ok, %{state | queued: state.queued ++ [result]}}
    end

    def handle_call({:write, data}, _from, state) do
      send(state.owner, {:uart_write, data})
      {:reply, :ok, state}
    end

    def handle_call(:close, _from, state) do
      if state.waiter do
        {waiter, timer} = state.waiter
        Process.cancel_timer(timer)
        GenServer.reply(waiter, {:error, :closed})
      end

      send(state.owner, :uart_closed)
      {:reply, :ok, %{state | waiter: nil}}
    end

    @impl true
    def handle_info({:read_timeout, from}, %{waiter: {from, _timer}} = state) do
      GenServer.reply(from, {:error, :timeout})
      {:noreply, %{state | waiter: nil}}
    end

    def handle_info({:read_timeout, _stale}, state), do: {:noreply, state}
  end

  defmodule BrokerTransport do
    alias AVModbus.UART
    alias AVModbus.UARTTest.FakeUART

    def open(options), do: UART.open_with(FakeUART, options)
    def write(handle, data), do: UART.write(handle, data)
    def read(handle, timeout_ms), do: UART.read(handle, timeout_ms)
    def close(handle), do: UART.close(handle)
  end

  setup do
    start_supervised!({FakeUART, self()})
    :ok
  end

  test "drains adjacent UART chunks using an instance-derived idle timeout" do
    uart = Process.whereis(FakeUART)
    :ok = FakeUART.push(uart, {:ok, "one"})
    :ok = FakeUART.push(uart, {:ok, "two"})
    :ok = FakeUART.push(uart, {:error, :timeout})

    {:ok, handle} = open_uart()
    assert UART.read(handle, 200) == {:ok, "onetwo"}

    assert UART.close(handle) == :ok
  end

  test "buffers data received before a transport read" do
    {:ok, handle} = open_uart()
    :ok = FakeUART.push(Process.whereis(FakeUART), {:ok, "buffered"})
    assert_receive {:uart_read, {:ok, "buffered"}}

    assert UART.read(handle, 200) == {:ok, "buffered"}
    assert UART.close(handle) == :ok
  end

  test "cancels a timed-out waiter without discarding later data" do
    {:ok, handle} = open_uart()
    assert UART.read(handle, 0) == {:error, :timeout}

    :ok = FakeUART.push(Process.whereis(FakeUART), {:ok, "late"})
    assert_receive {:uart_read, {:ok, "late"}}
    assert UART.read(handle, 200) == {:ok, "late"}

    assert UART.close(handle) == :ok
  end

  test "fails bounded reads on buffer overflow" do
    {:ok, handle} = open_uart()
    data = :binary.copy(<<0>>, 2_049)
    :ok = FakeUART.push(Process.whereis(FakeUART), {:ok, data})
    assert_receive {:uart_read, {:ok, ^data}}

    assert UART.read(handle, 200) == {:error, :overflow}
    assert UART.close(handle) == :ok
  end

  test "a terminal error discards buffered and delayed data" do
    {:ok, {UART, _adapter, _uart, broker} = handle} = open_uart()

    # These messages have one sender, so the broker processes them in order.
    send(broker, {UART, :data, "stale"})
    send(broker, {UART, :error, :disconnected})
    send(broker, {UART, :error, :later_failure})
    send(broker, {UART, :data, "late"})

    assert UART.read(handle, 200) == {:error, :disconnected}
    assert UART.read(handle, 200) == {:error, :disconnected}
    assert UART.close(handle) == :ok
  end

  test "a reader crash fails a pending read" do
    {:ok, {UART, _adapter, uart, broker} = handle} = open_uart()
    first_reference = make_ref()
    second_reference = make_ref()

    send(broker, {UART, :read, self(), first_reference})
    send(broker, {UART, :read, self(), second_reference})

    # The second reply proves that the first read is registered as the waiter.
    assert_receive {UART, ^second_reference, {:error, :ealready}}

    :ok = FakeUART.push(uart, {:crash, :reader_failed})

    assert_receive {UART, ^first_reference, {:error, {:uart_reader_down, :reader_failed}}}

    assert UART.close(handle) == :ok
  end

  test "a managed client reopens after its UART reader crashes" do
    uart = Process.whereis(FakeUART)

    {:ok, client} =
      Client.start_link(BrokerTransport,
        transport: :rtu,
        serial: [tx: 23, rx: 24, rx_idle_timeout: 1],
        gap: 0,
        backoff: {50, 50}
      )

    request = Task.async(fn -> Client.read_holding_registers(client, 1, 0, 1, timeout: 200) end)
    assert_receive {:uart_write, _frame}

    :ok = FakeUART.push(uart, {:crash, :reader_failed})

    assert Task.await(request) == {:error, :closed}
    assert Client.status(client) == {:disconnected, {:uart_reader_down, :reader_failed}}
    assert_receive :uart_closed
    assert wait_until(fn -> Client.status(client) == :connected end)

    {:ok, response} = RTU.encode(1, <<0x03, 0x02, 0x00, 0x2A>>)
    request = Task.async(fn -> Client.read_holding_registers(client, 1, 0, 1, timeout: 200) end)
    assert_receive {:uart_write, _frame}
    :ok = FakeUART.push(uart, {:ok, response})

    assert Task.await(request) == {:ok, [42]}
    assert Client.stop(client) == :ok
  end

  test "a terminal error remains visible when it follows a cancelled read" do
    {:ok, {UART, _adapter, _uart, broker} = handle} = open_uart()

    assert UART.read(handle, 0) == {:error, :timeout}
    send(broker, {UART, :error, :disconnected})
    send(broker, {UART, :data, "late"})

    assert UART.read(handle, 200) == {:error, :disconnected}
    assert UART.close(handle) == :ok
  end

  test "propagates UART errors and reader crashes" do
    {:ok, errored} = open_uart()
    :ok = FakeUART.push(Process.whereis(FakeUART), {:error, :disconnected})
    assert UART.read(errored, 200) == {:error, :disconnected}
    assert UART.close(errored) == :ok

    uart = Process.whereis(FakeUART)
    :ok = FakeUART.push(uart, {:ok, "partial"})
    :ok = FakeUART.push(uart, {:error, :disconnected_during_drain})
    {:ok, drain_error} = open_uart()
    assert UART.read(drain_error, 200) == {:error, :disconnected_during_drain}
    assert UART.close(drain_error) == :ok

    {:ok, crashed} = open_uart()
    :ok = FakeUART.push(Process.whereis(FakeUART), {:crash, :reader_failed})
    assert UART.read(crashed, 200) == {:error, {:uart_reader_down, :reader_failed}}
    assert UART.close(crashed) == :ok
  end

  test "closes the UART when its opening owner exits" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, handle} = open_uart()
        send(parent, {:opened, handle})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:opened, _handle}
    Process.exit(owner, :kill)
    assert_receive :uart_closed
  end

  test "closing the handle stops both broker and reader" do
    {:ok, {UART, _adapter, _uart, broker} = handle} = open_uart()
    assert_receive {:uart_waiting, reader}

    broker_monitor = Process.monitor(broker)
    reader_monitor = Process.monitor(reader)

    assert UART.close(handle) == :ok
    assert_receive {:DOWN, ^broker_monitor, :process, ^broker, :normal}
    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :normal}
  end

  defp open_uart do
    UART.open_with(FakeUART, tx: 23, rx: 24)
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(2)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: false
end
