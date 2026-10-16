defmodule DisterlProbe.Channel do
  @moduledoc """
  Ordered stop-and-wait channel for a transport feasibility test.

  Retransmits the head message in later polls, advances the queue only after
  an acknowledgment, and delivers a given sequence only once per peer
  session. Non-zero 16-bit sequence numbers wrap from 65,535 back to 1.
  """

  alias DisterlProbe.{Protocol, Session}

  @max_sequence 65_535
  @stale_ack_window div(@max_sequence, 2)

  def new(session \\ Session.new_id())
      when is_integer(session) and session in 1..4_294_967_295 do
    %{
      session: session,
      peer_session: nil,
      outgoing: nil,
      pending: [],
      outstanding: 0,
      sent: 0,
      received: 0
    }
  end

  def queue(%{outstanding: outstanding} = state, data)
      when outstanding < @max_sequence and is_binary(data) and byte_size(data) > 0 do
    sequence = next_sequence(state.sent)

    with {:ok, _packet} <-
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
            %{state | outgoing: message, sent: sequence, outstanding: outstanding + 1}

          _inflight ->
            %{
              state
              | pending: state.pending ++ [message],
                sent: sequence,
                outstanding: outstanding + 1
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

  def receive_packet(state, incoming) do
    session_changed = state.peer_session != incoming.session
    observed = observe_peer(state, incoming.session)

    with :ok <- check_ack(observed, incoming.acknowledged_session, incoming.acknowledgment),
         {:ok, next, delivered} <-
           accept(observed, incoming.sequence, incoming.payload, session_changed) do
      {outgoing, pending, outstanding} =
        case {incoming.acknowledged_session, next.outgoing} do
          {local_session, {acknowledgment, _payload}}
          when local_session == next.session and acknowledgment == incoming.acknowledgment ->
            {promoted, remaining} = promote(next.pending)
            {promoted, remaining, next.outstanding - 1}

          {_acknowledged_session, inflight} ->
            {inflight, next.pending, next.outstanding}
        end

      {:ok, %{next | outgoing: outgoing, pending: pending, outstanding: outstanding}, delivered}
    end
  end

  def done?(%{outgoing: nil, pending: []}), do: true
  def done?(_state), do: false

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
        pending: [],
        outstanding: 0,
        sent: 0,
        received: 0
    }
  end

  defp check_ack(%{session: session}, acknowledged_session, _acknowledgment)
       when acknowledged_session != session,
       do: :ok

  defp check_ack(_state, _acknowledged_session, 0), do: :ok

  defp check_ack(%{outgoing: {sequence, _payload}}, _acknowledged_session, acknowledgment) do
    if current_or_stale_ack?(acknowledgment, sequence),
      do: :ok,
      else: {:error, :invalid_acknowledgment}
  end

  defp check_ack(%{outgoing: nil, sent: sent}, _acknowledged_session, acknowledgment) do
    if current_or_stale_ack?(acknowledgment, sent),
      do: :ok,
      else: {:error, :invalid_acknowledgment}
  end

  defp check_ack(_state, _acknowledged_session, _acknowledgment),
    do: {:error, :invalid_acknowledgment}

  defp promote([next | rest]), do: {next, rest}
  defp promote([]), do: {nil, []}

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

  defp current_or_stale_ack?(_acknowledgment, 0), do: false

  defp current_or_stale_ack?(acknowledgment, reference) do
    backward_distance = rem(reference - acknowledgment + @max_sequence, @max_sequence)
    backward_distance <= @stale_ack_window
  end
end
