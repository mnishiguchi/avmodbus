defmodule DisterlProbe.Protocol do
  @moduledoc """
  Tiny experimental payload for Modbus user-defined function code 100.

  The enclosing Modbus RTU frame already provides the message boundary:
  <<version:8, session:32, sequence:16, acknowledged_session:32,
    acknowledgment:16, payload::binary>>.
  Sequence 0 means no outgoing message. This is NOT Erlang distribution.
  """

  @version 2
  # Keep the complete custom payload at the same 245-byte ceiling used by
  # version 1: thirteen header bytes plus at most 232 data bytes.
  @max_payload 232
  @header_size 13

  def max_payload, do: @max_payload
  def header_size, do: @header_size

  def encode(session, sequence, acknowledged_session, acknowledgment, payload)
      when is_integer(session) and session in 1..4_294_967_295 and
             is_integer(sequence) and sequence in 0..65_535 and
             is_integer(acknowledged_session) and acknowledged_session in 0..4_294_967_295 and
             is_integer(acknowledgment) and acknowledgment in 0..65_535 and
             is_binary(payload) and byte_size(payload) <= @max_payload and
             (acknowledged_session != 0 or acknowledgment == 0) and
             ((sequence == 0 and byte_size(payload) == 0) or
                (sequence > 0 and byte_size(payload) > 0)) do
    {:ok,
     <<@version, session::32, sequence::16, acknowledged_session::32, acknowledgment::16,
       payload::binary>>}
  end

  def encode(_session, _sequence, _acknowledged_session, _acknowledgment, _payload),
    do: {:error, :invalid_packet}

  def decode(
        <<@version, session::32, sequence::16, acknowledged_session::32, acknowledgment::16,
          payload::binary>>
      )
      when byte_size(payload) <= @max_payload and
             session > 0 and
             (acknowledged_session != 0 or acknowledgment == 0) and
             ((sequence == 0 and byte_size(payload) == 0) or
                (sequence > 0 and byte_size(payload) > 0)) do
    {:ok,
     %{
       session: session,
       sequence: sequence,
       acknowledged_session: acknowledged_session,
       acknowledgment: acknowledgment,
       payload: payload
     }}
  end

  def decode(_packet), do: {:error, :invalid_packet}
end
