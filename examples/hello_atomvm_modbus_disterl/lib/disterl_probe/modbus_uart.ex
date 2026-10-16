defmodule DisterlProbe.ModbusUART do
  @moduledoc """
  Experimental byte-stream adapter used as `serial_dist`'s `uart_module`.

  `serial_dist` sees the usual blocking `open/read/write/close` UART API. The
  adapter chunks writes into the FC-100 stop-and-wait channel and reassembles
  delivered chunks for reads. Only the client role polls the Modbus bus.
  """

  use GenServer

  alias AVModbus.{Client, Server}

  alias DisterlProbe.{
    Channel,
    MemorySnapshot,
    Protocol,
    ResponseFault,
    ResponseTimeout,
    TransactionStats
  }

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
  def queue_chunks(channel, data), do: queue_chunks(channel, data, @max_payload)

  def queue_chunks(channel, <<>>, chunk_payload_bytes)
      when is_integer(chunk_payload_bytes) and chunk_payload_bytes in 1..@max_payload,
      do: {:ok, channel}

  def queue_chunks(channel, data, chunk_payload_bytes)
      when is_integer(chunk_payload_bytes) and chunk_payload_bytes in 1..@max_payload and
             byte_size(data) <= chunk_payload_bytes,
      do: Channel.queue(channel, data)

  def queue_chunks(channel, data, chunk_payload_bytes)
      when is_integer(chunk_payload_bytes) and chunk_payload_bytes in 1..@max_payload do
    <<chunk::binary-size(chunk_payload_bytes), rest::binary>> = data

    with {:ok, next} <- Channel.queue(channel, chunk) do
      queue_chunks(next, rest, chunk_payload_bytes)
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
      channel:
        Channel.new(
          max_queued_bytes: Keyword.fetch!(options, :max_queued_bytes),
          max_queued_chunks: Keyword.fetch!(options, :max_queued_chunks)
        ),
      rx_buffer: <<>>,
      reader: nil,
      resource: nil,
      unit_id: Keyword.fetch!(options, :unit_id),
      response_timeout:
        ResponseTimeout.new(
          Keyword.fetch!(options, :timeout_ms),
          Keyword.fetch!(options, :bulk_timeout_ms)
        ),
      chunk_payload_bytes: Keyword.fetch!(options, :chunk_payload_bytes),
      poll_ms: Keyword.fetch!(options, :poll_ms),
      request_ref: nil,
      stats: TransactionStats.new(Keyword.get(options, :trace_transactions, false)),
      trace_queue: Keyword.get(options, :trace_queue, false),
      trace_queue_active: false,
      response_fault:
        ResponseFault.new(
          [
            drop_responses: Keyword.get(options, :fault_drop_responses, 0),
            min_payload_bytes: Keyword.get(options, :fault_min_payload_bytes, 96),
            after_ms: Keyword.get(options, :fault_after_ms, 10_000)
          ],
          now_ms()
        )
    }

    case open_transport(role, Keyword.fetch!(options, :serial), state) do
      {:ok, resource} ->
        IO.puts("modbus_uart: opened role=#{role} session=#{state.channel.session}")
        log_queue("opened", state, 0)
        if role == :client, do: send(self(), :poll)
        {:ok, %{state | resource: resource}}

      {:error, _reason} = error ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    log_stream_data("queued", data)

    case queue_chunks(state.channel, data, state.chunk_payload_bytes) do
      {:ok, channel} ->
        response_timeout =
          ResponseTimeout.observe_write(
            state.response_timeout,
            byte_size(data),
            state.chunk_payload_bytes
          )

        log_timeout_change(state.response_timeout, response_timeout, byte_size(data))

        next = %{
          state
          | channel: channel,
            response_timeout: response_timeout,
            trace_queue_active: state.trace_queue_active or traceable_write?(byte_size(data))
        }

        log_queue("accepted", next, byte_size(data))
        {:reply, :ok, next}

      {:error, _reason} = error ->
        IO.puts(
          "modbus_uart: queue rejected bytes=#{byte_size(data)} reason=#{inspect(elem(error, 1))}"
        )

        log_queue("rejected", state, byte_size(data))
        {:reply, error, state}
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
    with {:ok, incoming} <- Protocol.decode(payload),
         {:ok, next, reply} <- receive_decoded_exchange(state, incoming) do
      case ResponseFault.after_accept(
             next.response_fault,
             byte_size(incoming.payload),
             now_ms()
           ) do
        {:reply, response_fault} ->
          {:reply, {:ok, reply}, %{next | response_fault: response_fault}}

        {:drop, response_fault} ->
          log_dropped_response(response_fault, incoming)

          {:reply, {:error, {:exception, :server_device_failure}},
           %{next | response_fault: response_fault}}
      end
    else
      {:error, _reason} -> {:reply, {:error, {:exception, :illegal_data_value}}, state}
    end
  end

  # Elixir's generated fallback calls erlang:phash2/2, which AtomVM 0.7.0-beta.0
  # does not provide. Preserve the intended failure without that unsupported BIF.
  @impl true
  def handle_cast(message, state), do: {:stop, {:bad_cast, message}, state}

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
    Client.start_link(
      transport: :rtu,
      serial: serial,
      timeout: ResponseTimeout.current(state.response_timeout)
    )
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
           timeout: ResponseTimeout.current(state.response_timeout),
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
    with {:ok, incoming} <- Protocol.decode(binary) do
      receive_decoded_exchange(state, incoming)
    end
  end

  defp receive_decoded_exchange(state, incoming) do
    previous_channel = state.channel

    with {:ok, channel, delivered} <- Channel.receive_packet(previous_channel, incoming),
         stream <- reset_restarted_peer(state, incoming.session),
         next <- deliver(stream, channel, delivered),
         {:ok, reply} <- Channel.packet(next.channel) do
      {:ok, maybe_log_drained_queue(previous_channel, next), reply}
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
    reset_stream(state, nil)
  end

  defp reset_restarted_peer(state, incoming_session) do
    log_peer_restart(state.channel.peer_session, incoming_session)
    reset_stream(state, state.reader)
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

  defp reset_stream(state, reader) do
    %{
      state
      | reader: reader,
        rx_buffer: <<>>,
        response_timeout: ResponseTimeout.reset(state.response_timeout)
    }
  end

  defp schedule_poll(delay), do: Process.send_after(self(), :poll, delay)

  defp now_ms, do: :erlang.monotonic_time(:millisecond)

  defp log_peer_restart(previous, current) do
    IO.puts("modbus_uart: peer session changed #{previous} -> #{current}; resetting stream")
  end

  defp log_timeout_change(previous, current, write_size) do
    previous_ms = ResponseTimeout.current(previous)
    current_ms = ResponseTimeout.current(current)

    if previous_ms != current_ms do
      IO.puts(
        "modbus_uart: response timeout #{previous_ms} -> #{current_ms} ms after multi-chunk write bytes=#{write_size}"
      )
    end
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

  defp log_queue(_event, %{trace_queue: false}, _write_bytes), do: :ok
  defp log_queue("accepted", _state, write_bytes) when write_bytes in [2, 10], do: :ok

  defp log_queue(event, state, write_bytes) do
    IO.puts(
      "modbus_uart: queue event=#{event} write_bytes=#{write_bytes} " <>
        "queued_bytes=#{state.channel.queued_bytes} outstanding=#{state.channel.outstanding} " <>
        MemorySnapshot.format(MemorySnapshot.capture())
    )
  end

  defp maybe_log_drained_queue(
         %{queued_bytes: previous_bytes},
         %{channel: %{queued_bytes: 0}, trace_queue_active: true} = next
       )
       when previous_bytes > 0 do
    log_queue("drained", next, 0)
    %{next | trace_queue_active: false}
  end

  defp maybe_log_drained_queue(_previous_channel, next), do: next

  defp traceable_write?(write_bytes), do: write_bytes not in [2, 10]

  defp log_dropped_response(response_fault, incoming) do
    IO.puts(
      "modbus_uart: fault dropped accepted response count=#{response_fault.dropped} " <>
        "remaining=#{response_fault.remaining} sequence=#{incoming.sequence} " <>
        "payload_bytes=#{byte_size(incoming.payload)}"
    )
  end
end
