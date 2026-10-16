defmodule DisterlProbe.ModbusUART do
  @moduledoc """
  Experimental byte-stream adapter used as `serial_dist`'s `uart_module`.

  `serial_dist` sees the usual blocking `open/read/write/close` UART API. The
  adapter chunks writes into the FC-100 stop-and-wait channel and reassembles
  delivered chunks for reads. Only the client role polls the Modbus bus.
  """

  use GenServer

  alias AVModbus.{Client, Server}
  alias DisterlProbe.{Channel, Protocol, TransactionStats}

  @function_code 100
  @max_payload Protocol.max_payload()

  # serial_dist expects a UART handle directly, not an {:ok, handle} tuple.
  def open(options) when is_list(options) do
    case GenServer.start(__MODULE__, options) do
      {:ok, pid} -> pid
      {:error, _reason} = error -> error
    end
  end

  def close(pid) when is_pid(pid) do
    GenServer.stop(pid)
    :ok
  end

  def write(pid, data) when is_pid(pid) and is_binary(data),
    do: GenServer.call(pid, {:write, data}, :infinity)

  def read(pid) when is_pid(pid), do: GenServer.call(pid, {:read, :infinity}, :infinity)

  def read(pid, timeout)
      when is_pid(pid) and
             (timeout == :infinity or (is_integer(timeout) and timeout >= 0)),
      do: GenServer.call(pid, {:read, timeout}, :infinity)

  @doc false
  def queue_chunks(channel, <<>>), do: {:ok, channel}

  def queue_chunks(channel, data) when byte_size(data) <= @max_payload,
    do: Channel.queue(channel, data)

  def queue_chunks(channel, data) do
    <<chunk::binary-size(@max_payload), rest::binary>> = data

    with {:ok, next} <- Channel.queue(channel, chunk) do
      queue_chunks(next, rest)
    end
  end

  # AVModbus module-handler entry point for the server role.
  def handle_request(_unit, {:custom, @function_code, payload}, adapter) do
    GenServer.call(adapter, {:exchange, payload}, :infinity)
  end

  def handle_request(_unit, _request, _adapter),
    do: {:error, {:exception, :illegal_function}}

  @impl true
  def init(options) do
    role = Keyword.fetch!(options, :role)

    state = %{
      role: role,
      channel: Channel.new(),
      rx_buffer: <<>>,
      reader: nil,
      resource: nil,
      unit_id: Keyword.fetch!(options, :unit_id),
      timeout_ms: Keyword.fetch!(options, :timeout_ms),
      poll_ms: Keyword.fetch!(options, :poll_ms),
      request_ref: nil,
      stats: TransactionStats.new(Keyword.get(options, :trace_transactions, false))
    }

    case open_transport(role, Keyword.fetch!(options, :serial), state) do
      {:ok, resource} ->
        IO.puts("modbus_uart: opened role=#{role} session=#{state.channel.session}")
        if role == :client, do: send(self(), :poll)
        {:ok, %{state | resource: resource}}

      {:error, _reason} = error ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    log_stream_data("queued", data)

    case queue_chunks(state.channel, data) do
      {:ok, channel} -> {:reply, :ok, %{state | channel: channel}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:read, timeout}, from, %{rx_buffer: <<>>} = state) do
    state = replace_reader(state)
    reference = make_ref()

    timer =
      if timeout == :infinity,
        do: nil,
        else: Process.send_after(self(), {:read_timeout, reference}, timeout)

    {:noreply, %{state | reader: {from, reference, timer, timeout}}}
  end

  def handle_call({:read, _timeout}, _from, state) do
    {:reply, {:ok, state.rx_buffer}, %{state | rx_buffer: <<>>}}
  end

  def handle_call({:exchange, payload}, _from, %{role: :server} = state) do
    case receive_exchange(state, payload) do
      {:ok, next, reply} -> {:reply, {:ok, reply}, next}
      {:error, _reason} -> {:reply, {:error, {:exception, :illegal_data_value}}, state}
    end
  end

  @impl true
  def handle_info(:poll, %{role: :client, request_ref: nil} = state) do
    case Channel.packet(state.channel) do
      {:ok, request} ->
        send_poll(state, request)

      {:error, reason} ->
        log_adapter_failure(reason)
        schedule_poll(state.poll_ms)
        {:noreply, state}
    end
  end

  def handle_info({Client, reference, {:ok, response}}, %{request_ref: reference} = state) do
    state = complete_success(state, response)

    case receive_exchange(state, response) do
      {:ok, next, _unused_request} ->
        schedule_poll(next.poll_ms)
        {:noreply, %{next | request_ref: nil}}

      {:error, reason} ->
        log_adapter_failure(reason)
        schedule_poll(state.poll_ms)
        {:noreply, %{state | request_ref: nil}}
    end
  end

  def handle_info({Client, reference, {:error, reason}}, %{request_ref: reference} = state) do
    state = complete_failure(state, reason)
    schedule_poll(state.poll_ms)
    {:noreply, %{state | request_ref: nil}}
  end

  def handle_info(
        {:read_timeout, reference},
        %{reader: {from, reference, _timer, _timeout}} = state
      ) do
    GenServer.reply(from, {:error, :timeout})
    {:noreply, %{state | reader: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{role: :client, resource: resource}) when resource != nil do
    Client.stop(resource)
    :ok
  end

  def terminate(_reason, %{role: :server, resource: resource}) when is_pid(resource) do
    Server.RTU.stop(resource)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp open_transport(:client, serial, state) do
    Client.start_link(transport: :rtu, serial: serial, timeout: state.timeout_ms)
  end

  defp open_transport(:server, serial, state) do
    Server.RTU.start_link({__MODULE__, self()}, units: [state.unit_id], serial: serial)
  end

  defp send_poll(state, request) do
    stats = TransactionStats.start(state.stats, byte_size(request), now_ms())

    case Client.send_request(
           state.resource,
           state.unit_id,
           {:custom, @function_code, request},
           timeout: state.timeout_ms,
           to: self()
         ) do
      reference when is_reference(reference) ->
        {:noreply, %{state | request_ref: reference, stats: stats}}

      {:error, reason} ->
        state = complete_failure(%{state | stats: stats}, reason)
        schedule_poll(state.poll_ms)
        {:noreply, state}
    end
  end

  defp complete_success(state, response) do
    {stats, event} = TransactionStats.succeed(state.stats, byte_size(response), now_ms())
    log_transaction(stats, event)
    %{state | stats: stats}
  end

  defp complete_failure(state, reason) do
    {stats, event} = TransactionStats.fail(state.stats, reason, now_ms())
    log_transaction(stats, event)
    %{state | stats: stats}
  end

  defp receive_exchange(state, binary) do
    with {:ok, incoming} <- Protocol.decode(binary),
         {:ok, channel, delivered} <- Channel.receive_packet(state.channel, incoming),
         stream <- reset_restarted_peer(state, incoming.session),
         next <- deliver(stream, channel, delivered),
         {:ok, reply} <- Channel.packet(next.channel) do
      {:ok, next, reply}
    end
  end

  defp reset_restarted_peer(%{channel: %{peer_session: nil}} = state, _incoming_session),
    do: state

  defp reset_restarted_peer(
         %{channel: %{peer_session: session}} = state,
         incoming_session
       )
       when session == incoming_session,
       do: state

  defp reset_restarted_peer(
         %{reader: {from, _reference, timer, :infinity}} = state,
         incoming_session
       ) do
    if timer != nil, do: Process.cancel_timer(timer)
    GenServer.reply(from, {:error, :closed})
    log_peer_restart(state.channel.peer_session, incoming_session)
    %{state | reader: nil, rx_buffer: <<>>}
  end

  defp reset_restarted_peer(state, incoming_session) do
    log_peer_restart(state.channel.peer_session, incoming_session)
    %{state | rx_buffer: <<>>}
  end

  defp deliver(state, channel, nil), do: %{state | channel: channel}

  defp deliver(%{reader: nil} = state, channel, data),
    do: buffer_delivery(state, channel, data)

  defp deliver(%{reader: {from, _reference, timer, _timeout}} = state, channel, data) do
    if timer != nil, do: Process.cancel_timer(timer)
    log_stream_data("delivered", data)
    GenServer.reply(from, {:ok, data})
    %{state | channel: channel, reader: nil}
  end

  defp buffer_delivery(state, channel, data) do
    log_stream_data("buffered", data)
    %{state | channel: channel, rx_buffer: state.rx_buffer <> data}
  end

  defp replace_reader(%{reader: nil} = state), do: state

  defp replace_reader(%{reader: {from, _reference, timer, _timeout}} = state) do
    if timer != nil, do: Process.cancel_timer(timer)
    GenServer.reply(from, {:error, :closed})
    %{state | reader: nil}
  end

  defp schedule_poll(delay), do: Process.send_after(self(), :poll, delay)

  defp now_ms, do: :erlang.monotonic_time(:millisecond)

  defp log_peer_restart(previous, current) do
    IO.puts("modbus_uart: peer session changed #{previous} -> #{current}; resetting stream")
  end

  # serial_dist emits 2-byte sync markers before connection and 10-byte tick
  # frames afterward. Keep logs focused on handshake and application traffic.
  defp log_stream_data(_action, data) when byte_size(data) in [2, 10], do: :ok

  defp log_stream_data(action, data),
    do: IO.puts("modbus_uart: #{action} bytes=#{byte_size(data)}")

  defp log_transaction(stats, event) do
    if TransactionStats.enabled?(stats) and
         TransactionStats.trace_event?(event, Protocol.header_size()) do
      log_transaction_event(event)
    else
      log_initial_failure(event)
    end
  end

  defp log_transaction_event(%{outcome: :ok} = event) do
    IO.puts(
      "modbus_uart: transaction poll=#{event.poll} outcome=ok request_bytes=#{event.request_bytes} response_bytes=#{event.response_bytes} elapsed_ms=#{event.elapsed_ms} max_elapsed_ms=#{event.max_elapsed_ms} successes=#{event.successes} failures=#{event.failures}"
    )
  end

  defp log_transaction_event(%{outcome: :error} = event) do
    IO.puts(
      "modbus_uart: transaction poll=#{event.poll} outcome=error request_bytes=#{event.request_bytes} elapsed_ms=#{event.elapsed_ms} max_elapsed_ms=#{event.max_elapsed_ms} reason=#{inspect(event.reason)} successes=#{event.successes} failures=#{event.failures}"
    )
  end

  defp log_initial_failure(%{outcome: :error, failures: failures, reason: reason})
       when failures <= 3,
       do: IO.puts("modbus_uart: poll failed #{inspect(reason)}; retrying")

  defp log_initial_failure(_event), do: :ok

  defp log_adapter_failure(reason),
    do: IO.puts("modbus_uart: invalid exchange #{inspect(reason)}; retrying")
end
