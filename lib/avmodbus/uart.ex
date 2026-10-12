defmodule AVModbus.UART do
  @moduledoc """
  RS485 transceiver 経由の Modbus serial 通信に使う AtomVM UART adapter です。

  AtomVM の `uart:read/2` 呼び出し間で受信 byte を失わないよう、専用 reader が UART を
  継続して読み取ります。隣接 chunk は UART 固有の RX idle timeout まで drain してから、
  bounded broker が Client / Server からの read request に応答します。
  UART failure は terminal state とし、受信済み buffer より error を優先します。
  `open/1` では compile-time default を instance ごとに上書きできます。
  """

  @compile {:no_warn_undefined, :uart}
  @behaviour AVModbus.Serial.Transport

  @peripheral Application.compile_env(:avmodbus, :uart_peripheral, "UART1")
  @speed Application.compile_env(:avmodbus, :uart_speed, 9_600)
  @tx_pin Application.compile_env(:avmodbus, :uart_tx_pin, nil)
  @rx_pin Application.compile_env(:avmodbus, :uart_rx_pin, nil)
  @data_bits Application.compile_env(:avmodbus, :uart_data_bits, 8)
  @stop_bits Application.compile_env(:avmodbus, :uart_stop_bits, 1)
  @parity Application.compile_env(:avmodbus, :uart_parity, :none)
  @rx_idle_timeout Application.compile_env(:avmodbus, :uart_rx_idle_timeout_ms, 20)
  @buffer_limit 2_048
  @reader_timeout 60_000

  @type option ::
          {:peripheral, binary() | charlist()}
          | {:speed, pos_integer()}
          | {:tx, non_neg_integer()}
          | {:rx, non_neg_integer()}
          | {:data_bits, 5..8}
          | {:stop_bits, 1 | 2}
          | {:parity, :none | :even | :odd}
          | {:rx_idle_timeout, pos_integer()}

  @impl true
  @spec open([option()]) :: {:ok, term()} | {:error, term()}
  def open(options), do: open_with(:uart, options)

  @doc false
  @spec open_with(module(), [option()] | term()) :: {:ok, term()} | {:error, term()}
  def open_with(adapter, options) when is_atom(adapter) and is_list(options) do
    config = %{
      peripheral: option(options, :peripheral, @peripheral),
      speed: option(options, :speed, @speed),
      tx: option(options, :tx, @tx_pin),
      rx: option(options, :rx, @rx_pin),
      data_bits: option(options, :data_bits, @data_bits),
      stop_bits: option(options, :stop_bits, @stop_bits),
      parity: option(options, :parity, @parity),
      rx_idle_timeout: option(options, :rx_idle_timeout, @rx_idle_timeout)
    }

    with :ok <- validate_options(options), do: open_uart(adapter, config)
  end

  def open_with(_adapter, _options), do: {:error, :invalid_serial_options}

  @doc false
  @spec validate_options(term()) :: :ok | {:error, term()}
  def validate_options(options) when is_list(options), do: validate_serial_options(options)
  def validate_options(_options), do: {:error, :invalid_serial_options}

  defp open_uart(_adapter, %{tx: tx, rx: rx}) when is_nil(tx) or is_nil(rx),
    do: {:error, :uart_pins_not_configured}

  defp open_uart(adapter, config) do
    opts = [
      speed: config.speed,
      tx: config.tx,
      rx: config.rx,
      data_bits: config.data_bits,
      stop_bits: config.stop_bits,
      flow_control: :none,
      parity: config.parity
    ]

    case adapter.open(config.peripheral, opts) do
      {:error, _reason} = error ->
        error

      uart ->
        owner = self()
        idle_timeout_ms = rx_idle_timeout_ms(config)
        broker = spawn(fn -> broker_init(adapter, uart, owner, idle_timeout_ms) end)
        {:ok, {__MODULE__, adapter, uart, broker}}
    end
  end

  defp rx_idle_timeout_ms(config) do
    parity_bits = if config.parity == :none, do: 0, else: 1
    bits_per_character = 1 + config.data_bits + parity_bits + config.stop_bits
    character_timeout_ms = div(bits_per_character * 1_000 + config.speed - 1, config.speed) + 1
    max(character_timeout_ms, config.rx_idle_timeout)
  end

  defp validate_serial_options([]), do: :ok

  defp validate_serial_options([{:peripheral, value} | rest])
       when is_binary(value) or is_list(value),
       do: validate_serial_options(rest)

  defp validate_serial_options([{:speed, value} | rest])
       when is_integer(value) and value > 0,
       do: validate_serial_options(rest)

  defp validate_serial_options([{key, value} | rest])
       when key in [:tx, :rx] and is_integer(value) and value >= 0,
       do: validate_serial_options(rest)

  defp validate_serial_options([{:data_bits, value} | rest]) when value in 5..8,
    do: validate_serial_options(rest)

  defp validate_serial_options([{:stop_bits, value} | rest]) when value in [1, 2],
    do: validate_serial_options(rest)

  defp validate_serial_options([{:parity, value} | rest]) when value in [:none, :even, :odd],
    do: validate_serial_options(rest)

  defp validate_serial_options([{:rx_idle_timeout, value} | rest])
       when is_integer(value) and value > 0,
       do: validate_serial_options(rest)

  defp validate_serial_options([option | _rest]),
    do: {:error, {:invalid_serial_option, option}}

  defp option([], _key, default), do: default
  defp option([{key, value} | _rest], key, _default), do: value
  defp option([_option | rest], key, default), do: option(rest, key, default)

  @impl true
  def write({__MODULE__, adapter, uart, _broker}, data), do: adapter.write(uart, data)
  def write(uart, data), do: :uart.write(uart, data)

  @impl true
  def read({__MODULE__, _adapter, _uart, broker}, timeout_ms) do
    reference = make_ref()
    send(broker, {__MODULE__, :read, self(), reference})

    receive do
      {__MODULE__, ^reference, result} -> result
    after
      timeout_ms ->
        send(broker, {__MODULE__, :cancel, self(), reference})
        await_cancel(reference)
        {:error, :timeout}
    end
  end

  def read(uart, timeout_ms), do: :uart.read(uart, timeout_ms)

  @impl true
  def close({__MODULE__, adapter, uart, broker}) do
    reference = make_ref()
    send(broker, {__MODULE__, :stop, self(), reference})

    receive do
      {__MODULE__, ^reference, :ok} -> :ok
    after
      100 -> :ok
    end

    adapter.close(uart)
  end

  def close(uart), do: :uart.close(uart)

  defp broker_init(adapter, uart, owner, idle_timeout_ms) do
    owner_monitor = Process.monitor(owner)
    broker = self()
    reader = spawn(fn -> uart_reader_init(adapter, uart, broker, idle_timeout_ms) end)
    reader_monitor = Process.monitor(reader)

    broker_loop(%{
      adapter: adapter,
      uart: uart,
      owner_monitor: owner_monitor,
      reader_monitor: reader_monitor,
      buffer: <<>>,
      waiter: nil,
      error: nil
    })
  end

  defp broker_loop(state) do
    receive do
      {__MODULE__, :data, data} when is_binary(data) ->
        broker_loop(accept_data(state, data))

      {__MODULE__, :error, reason} ->
        broker_loop(fail(state, reason))

      {__MODULE__, :read, caller, reference} ->
        broker_loop(serve_read(state, caller, reference))

      {__MODULE__, :cancel, caller, reference} ->
        next = cancel_read(state, reference)
        send(caller, {__MODULE__, reference, :cancelled})
        broker_loop(next)

      {__MODULE__, :stop, caller, reference} ->
        send(caller, {__MODULE__, reference, :ok})
        :ok

      {:DOWN, owner_monitor, :process, _owner, _reason}
      when owner_monitor == state.owner_monitor ->
        state.adapter.close(state.uart)
        :ok

      {:DOWN, reader_monitor, :process, _reader, reason}
      when reader_monitor == state.reader_monitor ->
        next =
          if is_nil(state.error),
            do: fail(state, {:uart_reader_down, reason}),
            else: state

        broker_loop(next)

      _message ->
        broker_loop(state)
    end
  end

  defp uart_reader_init(adapter, uart, broker, idle_timeout_ms) do
    broker_monitor = Process.monitor(broker)
    uart_reader_loop(adapter, uart, broker, broker_monitor, idle_timeout_ms)
  end

  defp uart_reader_loop(adapter, uart, broker, broker_monitor, idle_timeout_ms) do
    receive do
      {:DOWN, ^broker_monitor, :process, ^broker, _reason} ->
        :ok
    after
      0 ->
        case adapter.read(uart, @reader_timeout) do
          {:ok, data} when is_binary(data) ->
            case read_available(adapter, uart, data, idle_timeout_ms) do
              {:ok, burst} ->
                send(broker, {__MODULE__, :data, burst})
                uart_reader_loop(adapter, uart, broker, broker_monitor, idle_timeout_ms)

              {:error, reason} ->
                send(broker, {__MODULE__, :error, reason})
            end

          {:error, :timeout} ->
            uart_reader_loop(adapter, uart, broker, broker_monitor, idle_timeout_ms)

          {:error, reason} ->
            send(broker, {__MODULE__, :error, reason})

          other ->
            send(broker, {__MODULE__, :error, {:uart_read, other}})
        end
    end
  end

  defp read_available(_adapter, _uart, data, _idle_timeout_ms)
       when byte_size(data) > @buffer_limit,
       do: {:error, :overflow}

  defp read_available(adapter, uart, data, idle_timeout_ms) do
    case adapter.read(uart, idle_timeout_ms) do
      {:ok, chunk} when is_binary(chunk) ->
        read_available(adapter, uart, <<data::binary, chunk::binary>>, idle_timeout_ms)

      {:error, :timeout} ->
        {:ok, data}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:uart_read, other}}
    end
  end

  defp accept_data(state, <<>>), do: state

  # A transport error is terminal for this broker.  Data already in flight from
  # the reader must not make a failed UART look healthy again.
  defp accept_data(%{error: error} = state, _data) when not is_nil(error), do: state

  defp accept_data(state, data) when byte_size(data) > @buffer_limit,
    do: fail(%{state | buffer: <<>>}, :overflow)

  defp accept_data(%{waiter: {caller, reference}} = state, data) do
    send(caller, {__MODULE__, reference, {:ok, data}})
    %{state | waiter: nil}
  end

  defp accept_data(state, data) do
    buffer = state.buffer <> data

    if byte_size(buffer) <= @buffer_limit do
      %{state | buffer: buffer}
    else
      fail(%{state | buffer: <<>>}, :overflow)
    end
  end

  defp fail(%{error: error} = state, _reason) when not is_nil(error),
    do: %{state | buffer: <<>>}

  defp fail(%{waiter: {caller, reference}} = state, reason) do
    send(caller, {__MODULE__, reference, {:error, reason}})
    %{state | buffer: <<>>, waiter: nil, error: reason}
  end

  defp fail(state, reason), do: %{state | buffer: <<>>, error: reason}

  defp serve_read(%{error: error} = state, caller, reference) when not is_nil(error) do
    send(caller, {__MODULE__, reference, {:error, error}})
    state
  end

  defp serve_read(%{buffer: buffer} = state, caller, reference) when buffer != <<>> do
    send(caller, {__MODULE__, reference, {:ok, buffer}})
    %{state | buffer: <<>>}
  end

  defp serve_read(%{waiter: nil} = state, caller, reference),
    do: %{state | waiter: {caller, reference}}

  defp serve_read(state, caller, reference) do
    send(caller, {__MODULE__, reference, {:error, :ealready}})
    state
  end

  defp cancel_read(%{waiter: {_caller, reference}} = state, reference),
    do: %{state | waiter: nil}

  defp cancel_read(state, _reference), do: state

  defp await_cancel(reference) do
    receive do
      {__MODULE__, ^reference, :cancelled} -> :ok
      {__MODULE__, ^reference, _late_result} -> await_cancel(reference)
    after
      100 -> :ok
    end
  end
end
