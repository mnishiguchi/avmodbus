defmodule DisterlProbe.Channel do
  @moduledoc """
  Ordered stop-and-wait channel for a transport feasibility test.

  Retransmits the head message in later polls, advances the queue only after
  an acknowledgment, and delivers a given sequence only once per peer
  session. Non-zero 16-bit sequence numbers wrap from 65,535 back to 1.
  Queue capacity is bounded independently by payload bytes and chunk count.
  """

  alias DisterlProbe.{Protocol, Session}

  @max_sequence 65_535
  @stale_ack_window div(@max_sequence, 2)
  @default_max_queued_bytes 8_192
  @default_max_queued_chunks 256

  def new, do: new(Session.new_id(), [])
  def new(options) when is_list(options), do: new(Session.new_id(), options)
  def new(session) when is_integer(session), do: new(session, [])

  def new(session, options)
      when is_integer(session) and session in 1..4_294_967_295 and is_list(options) do
    max_queued_bytes = Keyword.get(options, :max_queued_bytes, @default_max_queued_bytes)
    max_queued_chunks = Keyword.get(options, :max_queued_chunks, @default_max_queued_chunks)

    unless is_integer(max_queued_bytes) and max_queued_bytes > 0 and
             is_integer(max_queued_chunks) and max_queued_chunks in 1..@max_sequence do
      raise ArgumentError, "invalid channel queue limits"
    end

    %{
      session: session,
      peer_session: nil,
      outgoing: nil,
      pending: empty_queue(),
      outstanding: 0,
      queued_bytes: 0,
      max_queued_bytes: max_queued_bytes,
      max_queued_chunks: max_queued_chunks,
      sent: 0,
      received: 0
    }
  end

  @doc false
  def restart(state), do: restart(state, Session.new_id())

  @doc false
  def restart(state, session) do
    new(session,
      max_queued_bytes: state.max_queued_bytes,
      max_queued_chunks: state.max_queued_chunks
    )
  end

  def queue(state, data) when is_binary(data) and byte_size(data) > 0 do
    sequence = next_sequence(state.sent)
    data_size = byte_size(data)

    with :ok <- ensure_queue_capacity(state, data_size),
         {:ok, _packet} <-
           Protocol.encode(
             state.session,
             sequence,
             state.peer_session || 0,
             state.received,
             data
           ) do
      message = {sequence, data}

      next =
        case state.outgoing do
          nil ->
            %{
              state
              | outgoing: message,
                sent: sequence,
                outstanding: state.outstanding + 1,
                queued_bytes: state.queued_bytes + data_size
            }

          _inflight ->
            %{
              state
              | pending: enqueue(state.pending, message),
                sent: sequence,
                outstanding: state.outstanding + 1,
                queued_bytes: state.queued_bytes + data_size
            }
        end

      {:ok, next}
    end
  end

  def queue(_state, _data), do: {:error, :queue_unavailable}

  def packet(%{outgoing: nil} = state),
    do:
      Protocol.encode(
        state.session,
        0,
        state.peer_session || 0,
        state.received,
        <<>>
      )

  def packet(%{outgoing: {sequence, data}} = state),
    do:
      Protocol.encode(
        state.session,
        sequence,
        state.peer_session || 0,
        state.received,
        data
      )

  # Do not bind to a peer using a frame buffered across the local reboot.
  # Such a frame names the previous local session and belongs to its stream.
  def receive_packet(
        %{peer_session: nil, session: local_session} = state,
        %{acknowledged_session: acknowledged_session}
      )
      when acknowledged_session != 0 and acknowledged_session != local_session,
      do: {:ok, state, nil}

  def receive_packet(state, incoming) do
    session_changed = state.peer_session != incoming.session
    observed = observe_peer(state, incoming.session)

    with :ok <-
           check_ack(
             observed,
             incoming.acknowledged_session,
             incoming.acknowledgment,
             session_changed
           ),
         {:ok, next, delivered} <-
           accept(observed, incoming.sequence, incoming.payload, session_changed) do
      {outgoing, pending, outstanding, queued_bytes} =
        case {incoming.acknowledged_session, next.outgoing} do
          {local_session, {acknowledgment, payload}}
          when local_session == next.session and acknowledgment == incoming.acknowledgment ->
            {promoted, remaining} = promote(next.pending)
            {promoted, remaining, next.outstanding - 1, next.queued_bytes - byte_size(payload)}

          {_acknowledged_session, inflight} ->
            {inflight, next.pending, next.outstanding, next.queued_bytes}
        end

      {:ok,
       %{
         next
         | outgoing: outgoing,
           pending: pending,
           outstanding: outstanding,
           queued_bytes: queued_bytes
       }, delivered}
    end
  end

  def done?(%{outgoing: nil, pending: pending}), do: queue_empty?(pending)
  def done?(_state), do: false

  @doc false
  def pending_payloads(%{pending: pending}),
    do: Enum.map(queue_to_list(pending), fn {_sequence, payload} -> payload end)

  def complete?(state, expected_received)
      when is_integer(expected_received) and expected_received >= 0,
      do: done?(state) and state.received == expected_received

  defp observe_peer(%{peer_session: session} = state, session), do: state

  defp observe_peer(%{peer_session: nil} = state, session),
    do: %{state | peer_session: session, received: 0}

  defp observe_peer(state, session) do
    %{
      state
      | peer_session: session,
        outgoing: nil,
        pending: empty_queue(),
        outstanding: 0,
        queued_bytes: 0,
        sent: 0,
        received: 0
    }
  end

  # A peer can receive local data before its new session is observed here. Its
  # first reply may therefore acknowledge a sequence that the session reset
  # has just discarded. The new session is the synchronization boundary, so
  # validate acknowledgments only after that boundary has been established.
  defp check_ack(_state, _acknowledged_session, _acknowledgment, true), do: :ok

  defp check_ack(%{session: session}, acknowledged_session, _acknowledgment, false)
       when acknowledged_session != session,
       do: :ok

  defp check_ack(_state, _acknowledged_session, 0, false), do: :ok

  defp check_ack(
         %{outgoing: {sequence, _payload}},
         _acknowledged_session,
         acknowledgment,
         false
       ) do
    if current_or_stale_ack?(acknowledgment, sequence),
      do: :ok,
      else: {:error, :invalid_acknowledgment}
  end

  defp check_ack(%{outgoing: nil, sent: sent}, _acknowledged_session, acknowledgment, false) do
    if current_or_stale_ack?(acknowledgment, sent),
      do: :ok,
      else: {:error, :invalid_acknowledgment}
  end

  defp check_ack(_state, _acknowledged_session, _acknowledgment, false),
    do: {:error, :invalid_acknowledgment}

  defp promote({[next | front], rear}), do: {next, {front, rear}}

  defp promote({[], rear}) do
    case reverse(rear, []) do
      [next | front] -> {next, {front, []}}
      [] -> {nil, empty_queue()}
    end
  end

  defp accept(state, 0, <<>>, _session_changed), do: {:ok, state, nil}

  defp accept(state, sequence, data, true) when sequence > 0 and byte_size(data) > 0,
    do: {:ok, %{state | received: sequence}, data}

  defp accept(%{received: received} = state, sequence, _data, false)
       when sequence == received,
       do: {:ok, state, nil}

  defp accept(%{received: previous} = state, sequence, data, false)
       when byte_size(data) > 0 do
    if sequence == next_sequence(previous),
      do: {:ok, %{state | received: sequence}, data},
      else: {:error, :out_of_order}
  end

  defp accept(_state, _sequence, _data, _session_changed), do: {:error, :out_of_order}

  defp next_sequence(@max_sequence), do: 1
  defp next_sequence(sequence), do: sequence + 1

  defp ensure_queue_capacity(
         %{
           outstanding: outstanding,
           queued_bytes: queued_bytes,
           max_queued_chunks: max_queued_chunks,
           max_queued_bytes: max_queued_bytes
         },
         data_size
       )
       when outstanding < @max_sequence and outstanding < max_queued_chunks and
              queued_bytes + data_size <= max_queued_bytes,
       do: :ok

  defp ensure_queue_capacity(_state, _data_size), do: {:error, :queue_full}

  defp empty_queue, do: {[], []}
  defp enqueue({front, rear}, message), do: {front, [message | rear]}
  defp queue_empty?({[], []}), do: true
  defp queue_empty?(_queue), do: false
  defp queue_to_list({front, rear}), do: front ++ reverse(rear, [])

  defp reverse(list, accumulator), do: do_reverse(list, accumulator)
  defp do_reverse([], accumulator), do: accumulator
  defp do_reverse([head | tail], accumulator), do: do_reverse(tail, [head | accumulator])

  defp current_or_stale_ack?(_acknowledgment, 0), do: false

  defp current_or_stale_ack?(acknowledgment, reference) do
    backward_distance = rem(reference - acknowledgment + @max_sequence, @max_sequence)
    backward_distance <= @stale_ack_window
  end
end
