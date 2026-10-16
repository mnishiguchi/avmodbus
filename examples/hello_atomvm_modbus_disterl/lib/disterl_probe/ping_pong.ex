defmodule DisterlProbe.PingPong do
  @moduledoc false

  use GenServer

  alias DisterlProbe.Payload

  @name :modbus_disterl_demo
  @ping_count Application.compile_env(:disterl_probe, :ping_count, 3)
  @ping_delay_ms Application.compile_env(:disterl_probe, :ping_delay_ms, 2_000)
  @pong_timeout_ms Application.compile_env(:disterl_probe, :pong_timeout_ms, 15_000)
  @payload_bytes Application.compile_env(:disterl_probe, :ping_payload_bytes, 0)

  def start_link(identity, started_at),
    do: GenServer.start_link(__MODULE__, {identity, started_at}, name: @name)

  @impl true
  def init({identity, started_at}) do
    payload = Payload.build(@payload_bytes)
    IO.puts("modbus_disterl: registered #{inspect(@name)} payload_bytes=#{@payload_bytes}")

    if identity.role == :client do
      Process.send_after(self(), :send_ping, @ping_delay_ms)
    end

    {:ok,
     %{
       identity: identity,
       started_at: started_at,
       payload: payload,
       pending: nil,
       next_id: 1,
       remaining: @ping_count
     }}
  end

  # Elixir's generated fallbacks call erlang:phash2/2, which AtomVM
  # 0.7.0-beta.0 does not provide. Stop explicitly on unsupported messages.
  @impl true
  def handle_call(message, _from, state), do: {:stop, {:bad_call, message}, state}

  @impl true
  def handle_cast(message, state), do: {:stop, {:bad_cast, message}, state}

  @impl true
  def handle_info(:send_ping, %{remaining: 0} = state), do: {:noreply, state}

  def handle_info(:send_ping, %{pending: nil} = state) do
    id = state.next_id
    sent_at = :erlang.monotonic_time(:millisecond)

    IO.puts(
      "modbus_disterl: sending ping #{id} to #{inspect(state.identity.peer)} payload_bytes=#{byte_size(state.payload)}"
    )

    send({@name, state.identity.peer}, {:ping, self(), id, state.payload})
    Process.send_after(self(), {:pong_timeout, id}, @pong_timeout_ms)
    {:noreply, %{state | pending: {id, sent_at}}}
  end

  def handle_info({:ping, from, id, payload}, state) when is_pid(from) and is_binary(payload) do
    if valid_payload?(payload) do
      IO.puts(
        "modbus_disterl: received ping #{id} from #{inspect(node(from))} payload_bytes=#{byte_size(payload)}"
      )

      send(from, {:pong, node(), id, payload})
    else
      IO.puts("modbus_disterl: rejected ping #{id} invalid_payload_bytes=#{byte_size(payload)}")
    end

    {:noreply, state}
  end

  def handle_info(
        {:pong, from_node, id, payload},
        %{pending: {id, sent_at}, payload: expected} = state
      )
      when is_binary(payload) do
    if payload == expected do
      accept_pong(state, from_node, id, sent_at, byte_size(payload))
    else
      IO.puts("modbus_disterl: rejected pong #{id} invalid_payload_bytes=#{byte_size(payload)}")
      {:noreply, state}
    end
  end

  def handle_info({:pong_timeout, id}, %{pending: {id, _sent_at}} = state) do
    IO.puts("modbus_disterl: pong #{id} timed out; retrying")
    Process.send_after(self(), :send_ping, @ping_delay_ms)
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({:pong_timeout, _id}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp accept_pong(state, from_node, id, sent_at, payload_bytes) do
    now = :erlang.monotonic_time(:millisecond)
    rtt_ms = now - sent_at
    connection_ms = now - state.started_at

    IO.puts(
      "modbus_disterl: received pong #{id} from #{inspect(from_node)} rtt_ms=#{rtt_ms} payload_bytes=#{payload_bytes}"
    )

    if id == 1 do
      IO.puts("modbus_disterl: first remote reply connection_ms=#{connection_ms}")
    end

    next = %{
      state
      | pending: nil,
        next_id: id + 1,
        remaining: state.remaining - 1
    }

    if next.remaining == 0 do
      IO.puts("modbus_disterl: complete #{@ping_count} remote ping/pong messages")
    else
      Process.send_after(self(), :send_ping, @ping_delay_ms)
    end

    {:noreply, next}
  end

  defp valid_payload?(payload),
    do: byte_size(payload) == @payload_bytes and Payload.valid?(payload)
end
