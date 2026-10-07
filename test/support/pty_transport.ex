defmodule AVModbus.Test.PTYTransport do
  @moduledoc false

  use GenServer

  @bridge Path.expand("pty_bridge.py", __DIR__)

  def start_link(python), do: GenServer.start_link(__MODULE__, python)
  def path(transport), do: GenServer.call(transport, :path)
  def write(transport, data), do: GenServer.call(transport, {:write, data})
  def read(transport, timeout_ms), do: GenServer.call(transport, {:read, timeout_ms}, :infinity)
  def close(transport), do: GenServer.stop(transport)

  @impl true
  def init(python) do
    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        args: [@bridge]
      ])

    case ready(port, <<>>) do
      {:ok, path, buffer} ->
        {:ok, %{port: port, path: path, buffer: buffer, reader: nil}}

      {:error, reason} ->
        Port.close(port)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call({:write, data}, _from, state) when is_binary(data) do
    result = if Port.command(state.port, data), do: :ok, else: {:error, :closed}
    {:reply, result, state}
  end

  def handle_call({:read, _timeout_ms}, _from, %{buffer: buffer} = state)
      when buffer != <<>> do
    {:reply, {:ok, buffer}, %{state | buffer: <<>>}}
  end

  def handle_call({:read, timeout_ms}, from, %{reader: nil} = state)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    reference = make_ref()
    timer = Process.send_after(self(), {:read_timeout, reference}, timeout_ms)
    {:noreply, %{state | reader: {from, reference, timer}}}
  end

  def handle_call({:read, _timeout_ms}, _from, state),
    do: {:reply, {:error, :read_in_progress}, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, reader: nil} = state) do
    {:noreply, %{state | buffer: state.buffer <> data}}
  end

  def handle_info(
        {port, {:data, data}},
        %{port: port, reader: {from, _reference, timer}} = state
      ) do
    Process.cancel_timer(timer)
    GenServer.reply(from, {:ok, data})
    {:noreply, %{state | reader: nil}}
  end

  def handle_info({:read_timeout, reference}, %{reader: {from, reference, _timer}} = state) do
    GenServer.reply(from, {:error, :timeout})
    {:noreply, %{state | reader: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if state.reader do
      {from, _reference, timer} = state.reader
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :closed})
    end

    {:stop, {:bridge_exit, status}, %{state | reader: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp ready(port, buffer) do
    case :binary.match(buffer, <<"\n">>) do
      {newline, 1} ->
        <<line::binary-size(newline), _newline, rest::binary>> = buffer

        case line do
          <<"PTY:", path::binary>> -> {:ok, path, rest}
          _other -> {:error, {:invalid_bridge_ready, line}}
        end

      :nomatch ->
        receive do
          {^port, {:data, data}} -> ready(port, buffer <> data)
          {^port, {:exit_status, status}} -> {:error, {:bridge_exit, status}}
        after
          2_000 -> {:error, :bridge_timeout}
        end
    end
  end
end
