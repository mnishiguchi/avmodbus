defmodule AVModbus.Client.TCP do
  @moduledoc false

  @behaviour :gen_server

  alias AVModbus.{Client, PDU}
  alias AVModbus.TCP, as: Frame

  @impl true
  def init(config) do
    {backoff_min, backoff_max} = config.backoff

    state = %{
      host: config.host,
      port: config.port,
      max_pending: config.max_pending,
      max_queue: config.max_queue,
      check_unit: config.check_unit,
      connect_timeout: config.connect_timeout,
      timeout: config.timeout,
      backoff_min: backoff_min,
      backoff_max: backoff_max,
      reconnect_delay: backoff_min,
      status: :connecting,
      socket: nil,
      connector: nil,
      connect_timer: nil,
      buffer: <<>>,
      next_transaction: 0,
      pending: %{},
      queue: {[], []},
      heard_at: monotonic_time(),
      silent_since: nil
    }

    {:ok, connect(state)}
  end

  @impl true
  def handle_call(:client_type, _from, state), do: {:reply, :tcp, state}
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:request, unit_id, request, timing}, from, state) do
    {deadline_ms, allow_expired} = Client.resolve_request_timing(timing, state.timeout)
    entry = new_entry(unit_id, request, deadline_ms, allow_expired, {:call, from})
    {:noreply, submit(state, entry)}
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :unsupported_call}, state}

  @impl true
  def handle_cast(
        {:request, unit_id, request, timing, recipient, reference},
        state
      ) do
    {deadline_ms, allow_expired} = Client.resolve_request_timing(timing, state.timeout)
    entry = new_entry(unit_id, request, deadline_ms, allow_expired, {:send, recipient, reference})
    {:noreply, submit(state, entry)}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({:connected, connector, socket}, %{connector: connector} = state) do
    cancel_timer(state.connect_timer)

    next = %{
      state
      | socket: socket,
        connector: nil,
        connect_timer: nil,
        status: :connected,
        buffer: <<>>,
        heard_at: monotonic_time()
    }

    {:noreply, flush(next)}
  end

  def handle_info({:connected, _connector, socket}, state) do
    _result = :gen_tcp.close(socket)
    {:noreply, state}
  end

  def handle_info({:connect_failed, connector, reason}, %{connector: connector} = state) do
    cancel_timer(state.connect_timer)
    {:noreply, drop(%{state | connector: nil, connect_timer: nil}, reason)}
  end

  def handle_info({:connect_timeout, connector}, %{connector: connector} = state) do
    Process.exit(connector, :kill)
    {:noreply, drop(%{state | connector: nil, connect_timer: nil}, :timeout)}
  end

  def handle_info(:reconnect, %{status: {:disconnected, _reason}} = state),
    do: {:noreply, connect(state)}

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) when is_binary(data) do
    {:noreply, frames(%{state | buffer: <<state.buffer::binary, data::binary>>})}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:noreply, drop(state, :closed)}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: {:noreply, drop(state, reason)}

  def handle_info({:expire, id}, state), do: {:noreply, expire(state, id)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.connector, do: Process.exit(state.connector, :kill)
    if state.socket, do: :gen_tcp.close(state.socket)
    :ok
  end

  defp new_entry(unit_id, request, deadline_ms, allow_expired, reply) do
    %{
      id: make_ref(),
      unit_id: unit_id,
      request: request,
      deadline_ms: deadline_ms,
      allow_expired: allow_expired,
      reply: reply,
      timer: nil,
      sent_at: nil,
      pdu: nil
    }
  end

  defp submit(%{status: {:disconnected, _reason}} = state, entry) do
    reply(entry, {:error, :closed})
    state
  end

  defp submit(state, entry) do
    case PDU.encode_request(entry.request) do
      {:ok, pdu} ->
        if queue_full?(state) do
          reply(entry, {:error, :queue_full})
          state
        else
          timeout_ms = max(entry.deadline_ms - monotonic_ms(), 0)
          timer = Process.send_after(self(), {:expire, entry.id}, timeout_ms)
          queued = %{entry | pdu: pdu, timer: timer}
          flush(%{state | queue: queue_in(state.queue, queued)})
        end

      {:error, _reason} = error ->
        reply(entry, error)
        state
    end
  end

  defp flush(%{status: :connected} = state) when map_size(state.pending) < state.max_pending do
    case queue_out(state.queue) do
      {{:value, entry}, rest} ->
        dequeued = %{state | queue: rest}

        cond do
          entry.deadline_ms < monotonic_ms() and not entry.allow_expired ->
            cancel_timer(entry.timer)
            reply(entry, {:error, :timeout})
            flush(dequeued)

          true ->
            {transaction_id, next_transaction} =
              available_transaction(state.next_transaction, state.pending)

            {:ok, frame} = Frame.encode(transaction_id, entry.unit_id, entry.pdu)

            case :gen_tcp.send(state.socket, frame) do
              :ok ->
                sent = %{entry | sent_at: monotonic_time()}

                flush(%{
                  dequeued
                  | pending: Map.put(state.pending, transaction_id, sent),
                    next_transaction: next_transaction
                })

              {:error, reason} ->
                drop(%{dequeued | queue: queue_in_front(rest, entry)}, reason)

              other ->
                drop(
                  %{dequeued | queue: queue_in_front(rest, entry)},
                  {:tcp_send, other}
                )
            end
        end

      :empty ->
        state
    end
  end

  defp flush(state), do: state

  defp frames(state) do
    case Frame.decode(state.buffer) do
      {:ok, transaction_id, unit_id, pdu, rest} ->
        next = %{state | buffer: rest, heard_at: monotonic_time()}
        frames(answer(next, transaction_id, unit_id, pdu))

      {:discard, rest} ->
        frames(%{state | buffer: rest, heard_at: monotonic_time()})

      :more ->
        flush(state)

      {:error, _reason} ->
        drop(state, :invalid_frame)
    end
  end

  defp answer(state, transaction_id, unit_id, pdu) do
    case Map.fetch(state.pending, transaction_id) do
      :error ->
        state

      {:ok, entry} ->
        cancel_timer(entry.timer)

        result =
          if unit_id == entry.unit_id or not state.check_unit do
            PDU.decode_response(entry.request, pdu)
          else
            {:error, {:invalid_response, pdu}}
          end

        reply(entry, result)

        flush(%{
          state
          | pending: Map.delete(state.pending, transaction_id),
            reconnect_delay: state.backoff_min
        })
    end
  end

  defp expire(state, id) do
    case find_pending(state.pending, id) do
      {:ok, transaction_id, entry} ->
        reply(entry, {:error, :timeout})
        next = %{state | pending: Map.delete(state.pending, transaction_id)}

        cond do
          next.heard_at >= entry.sent_at ->
            flush(next)

          next.silent_since != nil and next.heard_at < next.silent_since ->
            drop(next, :timeout)

          true ->
            flush(%{next | silent_since: entry.sent_at})
        end

      :error ->
        {expired, kept} = remove_queued(queue_to_list(state.queue), id, [], [])
        reply_all(expired, {:error, :timeout})
        %{state | queue: {kept, []}}
    end
  end

  defp connect(state) do
    client = self()
    host = state.host
    port = state.port

    connector =
      spawn(fn ->
        connect_socket(client, host, port)
      end)

    timer = Process.send_after(self(), {:connect_timeout, connector}, state.connect_timeout)

    %{
      state
      | connector: connector,
        connect_timer: timer,
        status: :connecting
    }
  end

  defp connect_socket(client, host, port) do
    case :gen_tcp.connect(host, port, socket_options(host)) do
      {:ok, socket} ->
        case :gen_tcp.controlling_process(socket, client) do
          :ok ->
            send(client, {:connected, self(), socket})

          {:error, reason} ->
            :gen_tcp.close(socket)
            send(client, {:connect_failed, self(), reason})
        end

      {:error, reason} ->
        send(client, {:connect_failed, self(), reason})
    end
  end

  defp socket_options(host) when is_tuple(host) and tuple_size(host) == 8,
    do: [:inet6, :binary, active: true]

  defp socket_options(_host), do: [:binary, active: true]

  defp drop(state, reason) do
    if state.socket, do: :gen_tcp.close(state.socket)
    fail_pending(Map.to_list(state.pending))
    fail_all(queue_to_list(state.queue))
    Process.send_after(self(), :reconnect, state.reconnect_delay)

    %{
      state
      | socket: nil,
        status: {:disconnected, reason},
        buffer: <<>>,
        pending: %{},
        queue: {[], []},
        silent_since: nil,
        reconnect_delay: min(state.reconnect_delay * 2, state.backoff_max)
    }
  end

  defp fail_all([]), do: :ok

  defp fail_all([entry | rest]) do
    cancel_timer(entry.timer)
    reply(entry, {:error, :closed})
    fail_all(rest)
  end

  defp fail_pending([]), do: :ok

  defp fail_pending([{_transaction_id, entry} | rest]) do
    cancel_timer(entry.timer)
    reply(entry, {:error, :closed})
    fail_pending(rest)
  end

  defp reply_all([], _result), do: :ok

  defp reply_all([entry | rest], result) do
    reply(entry, result)
    reply_all(rest, result)
  end

  defp reply(%{reply: {:call, from}}, result), do: :gen_server.reply(from, result)

  defp reply(%{reply: {:send, recipient, reference}}, result),
    do: send(recipient, {Client, reference, result})

  defp available_transaction(transaction_id, pending) do
    next = rem(transaction_id + 1, 65_536)

    if Map.has_key?(pending, transaction_id),
      do: available_transaction(next, pending),
      else: {transaction_id, next}
  end

  defp find_pending(pending, id), do: find_pending_list(Map.to_list(pending), id)
  defp find_pending_list([], _id), do: :error

  defp find_pending_list([{transaction_id, %{id: id} = entry} | _rest], id),
    do: {:ok, transaction_id, entry}

  defp find_pending_list([_entry | rest], id), do: find_pending_list(rest, id)

  defp remove_queued([], _id, expired, kept),
    do: {reverse(expired, []), reverse(kept, [])}

  defp remove_queued([%{id: id} = entry | rest], id, expired, kept),
    do: remove_queued(rest, id, [entry | expired], kept)

  defp remove_queued([entry | rest], id, expired, kept),
    do: remove_queued(rest, id, expired, [entry | kept])

  defp queue_in({front, back}, entry), do: {front, [entry | back]}
  defp queue_in_front({front, back}, entry), do: {[entry | front], back}

  defp queue_out({[entry | rest], back}), do: {{:value, entry}, {rest, back}}
  defp queue_out({[], []}), do: :empty
  defp queue_out({[], back}), do: queue_out({reverse(back, []), []})

  defp queue_to_list({front, back}), do: append(front, reverse(back, []))
  defp append([], tail), do: tail
  defp append([value | rest], tail), do: [value | append(rest, tail)]

  defp list_length(values), do: list_length(values, 0)
  defp list_length([], result), do: result
  defp list_length([_value | rest], result), do: list_length(rest, result + 1)

  defp queue_full?(%{status: :connected} = state)
       when map_size(state.pending) < state.max_pending,
       do: false

  defp queue_full?(%{max_queue: :infinity}), do: false

  defp queue_full?(state) do
    {front, back} = state.queue
    list_length(front) + list_length(back) >= state.max_queue
  end

  defp reverse([], result), do: result
  defp reverse([value | rest], result), do: reverse(rest, [value | result])

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp monotonic_ms, do: :erlang.monotonic_time(:millisecond)
  defp monotonic_time, do: :erlang.monotonic_time()
end
