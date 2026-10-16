defmodule DisterlProbe do
  @moduledoc """
  Entry point for the logical transport and distributed Erlang experiments.
  """

  alias AVModbus.{Client, Server}
  alias DisterlProbe.{Channel, Mailbox, Protocol}

  @mode Application.compile_env(:disterl_probe, :mode, :transport)
  @role Application.compile_env(:disterl_probe, :role, :client)
  @serial Application.compile_env(:disterl_probe, :serial, [])
  @unit_id Application.compile_env(:disterl_probe, :unit_id, 1)
  @start_delay_ms Application.compile_env(:disterl_probe, :start_delay_ms, 0)
  @timeout_ms Application.compile_env(:disterl_probe, :timeout_ms, 1_000)
  @poll_ms Application.compile_env(:disterl_probe, :poll_ms, 1_000)
  @function_code 100
  @client_messages [<<"client message 1">>, <<"client message 2">>, <<"client message 3">>]
  @server_messages [<<"server message 1">>, <<"server message 2">>, <<"server message 3">>]
  @expected_messages 3

  def start do
    IO.puts(
      "disterl_probe: mode=#{@mode} role=#{@role} unit=#{@unit_id} function=#{@function_code}"
    )

    maybe_delay_start()

    case {@mode, @role} do
      {:disterl, _role} -> DisterlProbe.Distributed.start()
      {:transport, :server} -> start_server()
      {:transport, :client} -> start_client()
    end
  end

  defp start_server do
    with {:ok, mailbox} <- Mailbox.start_link(),
         {:ok, _queued} <- queue_messages(Mailbox, mailbox, @server_messages),
         {:ok, _server} <-
           Server.RTU.start_link({Mailbox, mailbox}, units: [@unit_id], serial: @serial) do
      IO.puts(
        "disterl_probe: server ready; #{length(@server_messages)} replies queued independently"
      )

      Process.sleep(:infinity)
    else
      error -> halt_with(error)
    end
  end

  defp start_client do
    with {:ok, client} <-
           Client.start_link(transport: :rtu, serial: @serial, timeout: @timeout_ms),
         {:ok, channel} <- queue_messages(Channel, Channel.new(), @client_messages) do
      IO.puts("disterl_probe: client started; #{length(@client_messages)} messages queued")
      poll(client, channel)
    else
      error -> halt_with(error)
    end
  end

  defp poll(client, channel) do
    result =
      with {:ok, request} <- Channel.packet(channel),
           {:ok, response} <-
             Client.custom(client, @unit_id, @function_code, request, timeout: @timeout_ms),
           {:ok, incoming} <- Protocol.decode(response),
           {:ok, next, delivered} <- Channel.receive_packet(channel, incoming) do
        if delivered != nil,
          do: IO.puts("disterl_probe: client received #{inspect(delivered)}")

        if incoming.sequence == 0 and Channel.complete?(next, @expected_messages) do
          IO.puts(
            "disterl_probe: complete (#{@expected_messages} ordered messages each way; all acknowledged)"
          )

          :done
        else
          {:continue, next}
        end
      end

    case result do
      :done ->
        Process.sleep(:infinity)

      {:continue, next} ->
        Process.sleep(@poll_ms)
        poll(client, next)

      {:error, reason} ->
        IO.puts("disterl_probe: exchange failed #{inspect(reason)}; retrying")
        Process.sleep(@poll_ms)
        poll(client, channel)
    end
  end

  defp halt_with(error) do
    IO.puts("disterl_probe: startup failed #{inspect(error)}")
    Process.sleep(:infinity)
  end

  defp maybe_delay_start do
    if @start_delay_ms > 0 do
      IO.puts("disterl_probe: delaying #{@start_delay_ms} ms before startup")
      Process.sleep(@start_delay_ms)
    end
  end

  defp queue_messages(module, initial, messages) do
    queue_messages_loop(module, initial, messages)
  end

  defp queue_messages_loop(_module, state, []), do: {:ok, state}

  defp queue_messages_loop(module, state, [message | rest]) do
    case module.queue(state, message) do
      :ok -> queue_messages_loop(module, state, rest)
      {:ok, next} -> queue_messages_loop(module, next, rest)
      {:error, _reason} = error -> error
    end
  end
end
