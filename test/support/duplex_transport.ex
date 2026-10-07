defmodule AVModbus.Test.DuplexTransport do
  @moduledoc false

  use GenServer

  def start_link, do: GenServer.start_link(__MODULE__, :ok)
  def endpoint(transport, side) when side in [:a, :b], do: {transport, side}
  def write({transport, side}, data), do: GenServer.call(transport, {:write, side, data})

  def read({transport, side}, timeout_ms),
    do: GenServer.call(transport, {:read, side, timeout_ms})

  def close(_endpoint), do: :ok

  @impl true
  def init(:ok) do
    endpoint = %{chunks: [], reader: nil}
    {:ok, %{a: endpoint, b: endpoint}}
  end

  @impl true
  def handle_call({:write, side, data}, _from, state) when is_binary(data) do
    peer = peer(side)
    {:reply, :ok, deliver(state, peer, data)}
  end

  def handle_call({:read, side, timeout_ms}, from, state)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    endpoint = Map.fetch!(state, side)

    case endpoint.chunks do
      [chunk | rest] ->
        {:reply, {:ok, chunk}, Map.put(state, side, %{endpoint | chunks: rest})}

      [] ->
        reference = make_ref()
        timer = Process.send_after(self(), {:read_timeout, side, reference}, timeout_ms)
        reader = {from, reference, timer}
        {:noreply, Map.put(state, side, %{endpoint | reader: reader})}
    end
  end

  @impl true
  def handle_info({:read_timeout, side, reference}, state) do
    endpoint = Map.fetch!(state, side)

    case endpoint.reader do
      {from, ^reference, _timer} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, Map.put(state, side, %{endpoint | reader: nil})}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp deliver(state, side, data) do
    endpoint = Map.fetch!(state, side)

    case endpoint.reader do
      {from, _reference, timer} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, data})
        Map.put(state, side, %{endpoint | reader: nil})

      nil ->
        Map.put(state, side, %{endpoint | chunks: endpoint.chunks ++ [data]})
    end
  end

  defp peer(:a), do: :b
  defp peer(:b), do: :a
end
