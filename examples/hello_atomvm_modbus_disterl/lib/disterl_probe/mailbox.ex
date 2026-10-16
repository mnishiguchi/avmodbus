defmodule DisterlProbe.Mailbox do
  @moduledoc """
  Server-side transport mailbox. The Modbus handler calls this process;
  it never owns or waits on the UART itself.
  """

  use GenServer

  alias DisterlProbe.{Channel, Protocol}

  def start_link, do: GenServer.start_link(__MODULE__, [])

  # Queue a message independently of an incoming Modbus request.
  def queue(server, payload), do: GenServer.call(server, {:queue, payload})

  # Called through AVModbus.Server's module handler contract.
  def handle_request(_unit, {:custom, 100, payload}, mailbox) do
    GenServer.call(mailbox, {:exchange, payload})
  end

  def handle_request(_unit, _request, _mailbox),
    do: {:error, {:exception, :illegal_function}}

  @impl true
  def init([]), do: {:ok, Channel.new()}

  @impl true
  def handle_call({:queue, payload}, _from, state) do
    case Channel.queue(state, payload) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:exchange, binary}, _from, state) do
    with {:ok, incoming} <- Protocol.decode(binary),
         {:ok, next, delivered} <- Channel.receive_packet(state, incoming),
         {:ok, reply} <- Channel.packet(next) do
      if delivered != nil, do: IO.puts("disterl_probe: server received #{inspect(delivered)}")
      {:reply, {:ok, reply}, next}
    else
      {:error, _reason} ->
        {:reply, {:error, {:exception, :illegal_data_value}}, state}
    end
  end

  # Elixir's generated fallback calls erlang:phash2/2, which AtomVM 0.7.0-beta.0
  # does not provide. Preserve the intended failure without that unsupported BIF.
  @impl true
  def handle_cast(message, state), do: {:stop, {:bad_cast, message}, state}
end
