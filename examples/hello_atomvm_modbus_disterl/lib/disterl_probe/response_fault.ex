defmodule DisterlProbe.ResponseFault do
  @moduledoc false

  def new(options \\ [], now_ms \\ 0) do
    %{
      remaining: Keyword.get(options, :drop_responses, 0),
      min_payload_bytes: Keyword.get(options, :min_payload_bytes, 96),
      armed_at_ms: now_ms + Keyword.get(options, :after_ms, 0),
      dropped: 0
    }
  end

  @doc false
  def after_accept(%{remaining: remaining} = state, payload_bytes, now_ms)
      when remaining > 0 and payload_bytes >= state.min_payload_bytes and
             now_ms >= state.armed_at_ms do
    {:drop, %{state | remaining: remaining - 1, dropped: state.dropped + 1}}
  end

  def after_accept(state, _payload_bytes, _now_ms), do: {:reply, state}
end
