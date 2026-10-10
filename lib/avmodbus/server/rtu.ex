defmodule AVModbus.Server.RTU do
  @moduledoc """
  serial transport 上で動作する Modbus RTU server process です。

  1 本の UART を所有し、fragmented request の再構築、line noise の除去、unit filtering、
  no-response の broadcast write を処理し、request semantics は `AVModbus.Server` に委譲します。

  `start_link/2` は configured AtomVM UART を開きます。`start_link/4` は open 済み transport handle を受け取り、
  UART を application 側で管理する場合や host-side tests に利用できます。
  """

  import Bitwise

  alias AVModbus.{ASCII, PDU, RTU, Serial, Server, UART}
  alias AVModbus.Server.Identification

  @behaviour :gen_server

  @default_echo Application.compile_env(:avmodbus, :modbus_echo, false)
  @default_silence Application.compile_env(:avmodbus, :modbus_silence_ms, 20)
  @default_speed Application.compile_env(:avmodbus, :uart_speed, 9_600)
  @default_gap_ms div(AVModbus.RTU.frame_gap_us(@default_speed) + 999, 1_000)
  @default_handler_timeout Application.compile_env(
                             :avmodbus,
                             :modbus_handler_timeout_ms,
                             10_000
                           )
  @default_backoff Application.compile_env(
                     :avmodbus,
                     :modbus_reconnect_backoff,
                     {100, 5_000}
                   )

  @diagnostic_counters %{
    0x0B => :bus_message,
    0x0C => :bus_communication_error,
    0x0D => :bus_exception_error,
    0x0E => :server_message,
    0x0F => :server_no_response,
    0x10 => :server_nak,
    0x11 => :server_busy,
    0x12 => :bus_character_overrun
  }
  @zero_counters Map.new(Map.values(@diagnostic_counters), &{&1, 0})
  @ascii_in_frame ~c"0123456789ABCDEFabcdef:\r"

  @type server :: pid() | atom()
  @type t :: {__MODULE__, server()}
  @type option ::
          {:mode, :rtu | :ascii}
          | {:units, [1..247]}
          | {:echo, boolean()}
          | {:silence, pos_integer()}
          | {:gap, non_neg_integer()}
          | {:handler_timeout, pos_integer() | :infinity}
          | {:backoff, {pos_integer(), pos_integer()}}
          | {:authorize, Server.authorize() | nil}
          | {:identification, Identification.objects() | nil}
          | {:name, atom()}

  @doc false
  def child_spec(options) when is_list(options) do
    %{
      id: option(options, :name, __MODULE__),
      start: {__MODULE__, :start_supervised, [options]}
    }
  end

  @doc false
  def start_supervised(options) when is_list(options) do
    with {:ok, handler, server_options} <- take_handler(options),
         {:ok, {__MODULE__, pid}} <- start_link(handler, server_options) do
      {:ok, pid}
    end
  end

  def start_supervised(_options), do: {:error, :invalid_options}

  @doc "configured UART を開き、`handler` 用の RTU server を起動します。"
  @spec start_link(Server.handler(), [option()]) :: {:ok, t()} | {:error, term()}
  def start_link(handler, options \\ [])

  def start_link(handler, options) when is_list(options) do
    with {:ok, name} <- server_name(options),
         {:ok, config} <- server_config(handler, options) do
      start_server({:open, UART, handler, config}, name)
    end
  end

  def start_link(_handler, _options), do: {:error, :invalid_options}

  @doc false
  @spec start_link(module(), Server.handler(), [option()]) :: {:ok, t()} | {:error, term()}
  def start_link(transport, handler, options) when is_atom(transport) and is_list(options) do
    with {:ok, name} <- server_name(options),
         {:ok, config} <- server_config(handler, options) do
      start_server({:open, transport, handler, config}, name)
    end
  end

  def start_link(_transport, _handler, _options), do: {:error, :invalid_options}

  @doc "open 済み transport handle 上で RTU server を起動します。"
  @spec start_link(module(), term(), Server.handler(), [option()]) ::
          {:ok, t()} | {:error, term()}
  def start_link(transport, uart, handler, options)
      when is_atom(transport) and is_list(options) do
    with {:ok, name} <- server_name(options),
         {:ok, config} <- server_config(handler, options) do
      start_server({:ready, transport, uart, handler, false, config}, name)
    end
  end

  def start_link(_transport, _uart, _handler, _options), do: {:error, :invalid_options}

  @doc "server を停止し、自身で open した UART を close します。"
  @spec close(t() | server()) :: :ok
  def close({__MODULE__, server}) when is_pid(server) or is_atom(server),
    do: :gen_server.stop(server)

  def close(server) when is_pid(server) or is_atom(server), do: :gen_server.stop(server)

  @doc "server を停止し、自身で open した UART を close します。"
  @spec stop(t() | server()) :: :ok
  def stop(server), do: close(server)

  @doc "`:connected` または reopen 中の最新 transport error を返します。"
  @spec status(t() | server()) :: :connected | {:disconnected, term()}
  def status({__MODULE__, server}) when is_pid(server) or is_atom(server),
    do: :gen_server.call(server, :status)

  def status(server) when is_pid(server) or is_atom(server),
    do: :gen_server.call(server, :status)

  @impl true
  def init({:open, transport, handler, config}) do
    state = new_state(transport, nil, handler, true, config)
    {:ok, open(state)}
  end

  def init({:ready, transport, uart, handler, close_on_stop, config}) do
    state = new_state(transport, uart, handler, close_on_stop, config)
    send(self(), :poll)
    {:ok, %{state | status: :connected}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(_message, _from, state), do: {:reply, {:error, :unsupported_call}, state}

  @impl true
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(:poll, %{status: :connected} = state) do
    case poll(state) do
      {:ok, next} ->
        send(self(), :poll)
        {:noreply, next}

      {:stop, reason, next} ->
        if next.close_on_stop do
          {:noreply, drop(next, reason)}
        else
          {:stop, reason, next}
        end
    end
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info(:reopen, %{status: {:disconnected, _reason}} = state),
    do: {:noreply, open(state)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{transport: transport, uart: uart, close_on_stop: true})
      when not is_nil(uart) do
    _result = transport.close(uart)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp new_state(transport, uart, handler, close_on_stop, config) do
    {backoff_min, backoff_max} = config.backoff

    %{
      transport: transport,
      uart: uart,
      handler: handler,
      close_on_stop: close_on_stop,
      mode: config.mode,
      delimiter: ?\n,
      units: config.units,
      echo: config.echo,
      silence: config.silence,
      gap: config.gap,
      handler_timeout: config.handler_timeout,
      authorize: config.authorize,
      identification: config.identification,
      backoff_min: backoff_min,
      backoff_max: backoff_max,
      reopen_delay: backoff_min,
      status: if(is_nil(uart), do: :connecting, else: :connected),
      echoing: <<>>,
      buffer: <<>>,
      garbage: false,
      counters: @zero_counters,
      events: [],
      event_count: 0,
      listen_only: false
    }
  end

  defp open(state) do
    case state.transport.open() do
      {:ok, uart} ->
        send(self(), :poll)
        %{state | uart: uart, status: :connected, reopen_delay: state.backoff_min}

      {:error, reason} ->
        schedule_reopen(state, reason)

      other ->
        schedule_reopen(state, {:transport_open, other})
    end
  end

  defp drop(state, reason) do
    if state.uart, do: state.transport.close(state.uart)
    schedule_reopen(%{state | uart: nil}, reason)
  end

  defp schedule_reopen(state, reason) do
    Process.send_after(self(), :reopen, state.reopen_delay)

    %{
      state
      | status: {:disconnected, reason},
        buffer: <<>>,
        echoing: <<>>,
        garbage: false,
        reopen_delay: min(state.reopen_delay * 2, state.backoff_max)
    }
  end

  defp poll(state) do
    case state.transport.read(state.uart, state.silence) do
      {:ok, data} when is_binary(data) and data != <<>> ->
        {echoing, input} = Serial.strip_echo(state.echoing, data)
        consume(%{state | echoing: echoing, buffer: state.buffer <> input})

      {:ok, <<>>} ->
        complete_silence(state)

      {:error, :timeout} ->
        complete_silence(state)

      {:error, reason} ->
        {:stop, reason, state}

      other ->
        {:stop, {:transport_read, other}, state}
    end
  end

  defp consume(%{mode: :rtu} = state) do
    case RTU.split_request(state.buffer) do
      {:ok, frame, rest} ->
        {:ok, unit_id, pdu} = RTU.decode(frame)

        case dispatch(%{state | buffer: rest, garbage: false}, unit_id, pdu) do
          {:ok, next} -> consume(next)
          {:stop, _reason, _next} = stop -> stop
        end

      :skip ->
        <<_byte, rest::binary>> = state.buffer
        consume(%{garbled(state) | buffer: rest})

      :overflow ->
        {:ok,
         state
         |> count(:bus_character_overrun)
         |> Map.merge(%{buffer: <<>>, garbage: false})}

      _more_or_unknown ->
        {:ok, state}
    end
  end

  defp consume(%{mode: :ascii} = state) do
    case ASCII.split(state.buffer, state.delimiter) do
      {:ok, frame, rest} ->
        case ASCII.decode(frame) do
          {:ok, unit_id, pdu} ->
            case dispatch(%{state | buffer: rest, garbage: false}, unit_id, pdu) do
              {:ok, next} -> consume(next)
              {:stop, _reason, _next} = stop -> stop
            end

          {:error, _reason} ->
            consume(%{garbled(state) | buffer: rest})
        end

      {:skip, rest} ->
        consume(%{garbled(state) | buffer: rest})

      :more ->
        {:ok, state}
    end
  end

  defp complete_silence(%{buffer: <<>>} = state), do: {:ok, %{state | garbage: false}}

  defp complete_silence(%{mode: :rtu} = state) do
    case RTU.complete_silence_request(state.buffer) do
      {:ok, frame} ->
        {:ok, unit_id, pdu} = RTU.decode(frame)
        dispatch(%{state | buffer: <<>>, garbage: false}, unit_id, pdu)

      {:error, _reason} ->
        {:ok, %{garbled(state) | buffer: <<>>, garbage: false}}
    end
  end

  defp complete_silence(%{mode: :ascii} = state),
    do: {:ok, %{garbled(state) | buffer: <<>>, garbage: false}}

  defp dispatch(state, unit_id, pdu) do
    state = count(state, :bus_message)

    if unit_id == 0 or unit_id in state.units do
      request(state, unit_id, pdu)
    else
      {:ok, state}
    end
  end

  defp request(state, unit_id, pdu) do
    state =
      state
      |> count(:server_message)
      |> event(0x80 ||| broadcast_bit(unit_id) ||| listen_bit(state))

    decoded = PDU.decode_request(pdu)

    cond do
      state.listen_only -> listening(state, unit_id, decoded)
      unit_id == 0 -> broadcast(state, pdu, decoded)
      true -> addressed(state, unit_id, pdu, decoded)
    end
  end

  defp listening(state, unit_id, {:ok, {:diagnostics, 1, [option]}})
       when option in [0, 0xFF00] do
    request = {:diagnostics, 1, [option]}

    if allowed?(state, unit_id, request) do
      {:ok, restart(state, option)}
    else
      {:ok, count(state, :server_no_response)}
    end
  end

  defp listening(state, _unit_id, _decoded),
    do: {:ok, count(state, :server_no_response)}

  defp broadcast(state, pdu, {:ok, request}) do
    state = count(state, :server_no_response)

    if PDU.broadcast_request?(request) do
      case server_respond(state, 0, pdu) do
        {:ok, <<function, _rest::binary>>} when function >= 0x80 ->
          {:ok, count(state, :bus_exception_error)}

        {:ok, _response} ->
          {:ok, %{state | event_count: state.event_count + 1}}

        :ignore ->
          {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  defp broadcast(state, _pdu, {:error, _exception}) do
    {:ok,
     state
     |> count(:server_no_response)
     |> count(:bus_exception_error)}
  end

  defp addressed(state, unit_id, pdu, {:ok, request}),
    do: respond(state, unit_id, pdu, request)

  defp addressed(state, unit_id, pdu, {:error, _exception}) do
    case server_respond(state, unit_id, pdu) do
      {:ok, response_pdu} -> reply(state, unit_id, nil, response_pdu)
      :ignore -> {:ok, state}
    end
  end

  defp respond(state, unit_id, _pdu, {:diagnostics, sub_function, data} = request) do
    if allowed?(state, unit_id, request) do
      diagnostics(state, unit_id, request, sub_function, data)
    else
      forbidden(state, unit_id, request)
    end
  end

  defp respond(state, unit_id, _pdu, :get_comm_event_counter = request) do
    if allowed?(state, unit_id, request) do
      result = {:ok, %{status: 0, event_count: state.event_count}}
      encode_and_reply(state, unit_id, request, result)
    else
      forbidden(state, unit_id, request)
    end
  end

  defp respond(state, unit_id, _pdu, :get_comm_event_log = request) do
    if allowed?(state, unit_id, request) do
      result =
        {:ok,
         %{
           status: 0,
           event_count: state.event_count,
           message_count: state.counters.bus_message,
           events: state.events
         }}

      encode_and_reply(state, unit_id, request, result)
    else
      forbidden(state, unit_id, request)
    end
  end

  defp respond(state, unit_id, pdu, request) do
    case server_respond(state, unit_id, pdu) do
      {:ok, response_pdu} -> reply(state, unit_id, request, response_pdu)
      :ignore -> {:ok, state}
    end
  end

  defp forbidden(state, unit_id, request),
    do: encode_and_reply(state, unit_id, request, {:error, {:exception, :illegal_function}})

  defp allowed?(state, unit_id, request) do
    Server.allowed?(state.authorize, nil, unit_id, request, state.handler_timeout)
  end

  defp server_respond(state, unit_id, pdu) do
    policy = %{
      authorize: state.authorize,
      identification: state.identification,
      role: nil
    }

    Server.respond(state.handler, unit_id, pdu, state.handler_timeout, policy)
  end

  defp diagnostics(state, unit_id, request, 0, data),
    do: encode_and_reply(state, unit_id, request, {:ok, data})

  defp diagnostics(state, unit_id, request, 1, [option]) when option in [0, 0xFF00] do
    case encode_and_reply(state, unit_id, request, {:ok, [option]}) do
      {:ok, next} -> {:ok, restart(next, option)}
      {:stop, _reason, _next} = stop -> stop
    end
  end

  defp diagnostics(state, unit_id, request, 2, [0]),
    do: encode_and_reply(state, unit_id, request, {:ok, [0]})

  defp diagnostics(%{mode: :ascii} = state, unit_id, request, 3, [delimiter])
       when band(delimiter, 0xFF) == 0 and (delimiter >>> 8) in @ascii_in_frame,
       do:
         encode_and_reply(
           state,
           unit_id,
           request,
           {:error, {:exception, :illegal_data_value}}
         )

  defp diagnostics(%{mode: :ascii} = state, unit_id, request, 3, [delimiter])
       when band(delimiter, 0xFF) == 0 do
    case encode_and_reply(state, unit_id, request, {:ok, [delimiter]}) do
      {:ok, next} -> {:ok, %{next | delimiter: delimiter >>> 8}}
      {:stop, _reason, _next} = stop -> stop
    end
  end

  defp diagnostics(state, _unit_id, _request, 4, [0]) do
    {:ok,
     state
     |> count(:server_no_response)
     |> Map.put(:listen_only, true)
     |> event(0x04)}
  end

  defp diagnostics(state, unit_id, request, 10, [0]) do
    case encode_and_reply(state, unit_id, request, {:ok, [0]}) do
      {:ok, next} -> {:ok, %{next | counters: @zero_counters, event_count: 0}}
      {:stop, _reason, _next} = stop -> stop
    end
  end

  defp diagnostics(state, unit_id, request, sub_function, [0])
       when is_map_key(@diagnostic_counters, sub_function) do
    value = rem(state.counters[@diagnostic_counters[sub_function]], 65_536)
    encode_and_reply(state, unit_id, request, {:ok, [value]})
  end

  defp diagnostics(state, unit_id, request, 20, [0]) do
    case encode_and_reply(state, unit_id, request, {:ok, [0]}) do
      {:ok, next} ->
        counters = %{next.counters | bus_character_overrun: 0}
        {:ok, %{next | counters: counters}}

      {:stop, _reason, _next} = stop ->
        stop
    end
  end

  defp diagnostics(state, unit_id, request, sub_function, _data)
       when sub_function in [1, 2, 3, 4, 10, 20] or
              is_map_key(@diagnostic_counters, sub_function),
       do:
         encode_and_reply(
           state,
           unit_id,
           request,
           {:error, {:exception, :illegal_data_value}}
         )

  defp diagnostics(state, unit_id, request, _sub_function, _data),
    do: encode_and_reply(state, unit_id, request, {:error, {:exception, :illegal_function}})

  defp encode_and_reply(state, unit_id, request, result) do
    case PDU.encode_response(request, result) do
      {:ok, response_pdu} ->
        reply(state, unit_id, request, response_pdu)

      {:error, _reason} ->
        {:ok, function} = PDU.function(request)
        {:ok, response_pdu} = PDU.encode_exception(function, :server_device_failure)
        reply(state, unit_id, request, response_pdu)
    end
  end

  defp reply(state, unit_id, request, response_pdu) do
    with {:ok, frame} <- encode_frame(state, unit_id, response_pdu) do
      if state.gap > 0, do: Process.sleep(state.gap)

      case state.transport.write(state.uart, frame) do
        :ok ->
          next = %{state | echoing: if(state.echo, do: frame, else: <<>>)}
          {:ok, sent(next, request, response_pdu)}

        {:error, reason} ->
          {:stop, reason, state}

        other ->
          {:stop, {:transport_write, other}, state}
      end
    else
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp sent(state, _request, <<function, code>>) when function >= 0x80 do
    state = count(state, :bus_exception_error)
    state = if code == 6, do: count(state, :server_busy), else: state
    state = if code == 7, do: count(state, :server_nak), else: state

    exception_bit =
      cond do
        code in 1..3 -> 0x01
        code == 4 -> 0x02
        code in 5..6 -> 0x04
        code == 7 -> 0x08
        true -> 0
      end

    event(state, 0x40 ||| exception_bit ||| listen_bit(state))
  end

  defp sent(state, request, _response_pdu) do
    state =
      if request == :get_comm_event_counter,
        do: state,
        else: %{state | event_count: state.event_count + 1}

    event(state, 0x40 ||| listen_bit(state))
  end

  defp restart(state, option) do
    events = if option == 0xFF00, do: [], else: state.events

    %{
      state
      | listen_only: false,
        counters: @zero_counters,
        event_count: 0,
        events: events,
        delimiter: ?\n
    }
    |> event(0x00)
  end

  defp garbled(%{garbage: true} = state), do: state
  defp garbled(state), do: %{count(state, :bus_communication_error) | garbage: true}

  defp count(state, counter) do
    counters = Map.put(state.counters, counter, Map.get(state.counters, counter) + 1)
    %{state | counters: counters}
  end

  defp event(state, value), do: %{state | events: take([value | state.events], 64)}

  defp take(values, count), do: take(values, count, [])
  defp take(_values, 0, result), do: reverse(result, [])
  defp take([], _count, result), do: reverse(result, [])
  defp take([value | rest], count, result), do: take(rest, count - 1, [value | result])

  defp reverse([], result), do: result
  defp reverse([value | rest], result), do: reverse(rest, [value | result])

  defp broadcast_bit(0), do: 0x40
  defp broadcast_bit(_unit_id), do: 0

  defp listen_bit(%{listen_only: true}), do: 0x20
  defp listen_bit(_state), do: 0

  defp start_server(init_arg, name) do
    case gen_server_start(init_arg, name) do
      {:ok, pid} -> {:ok, {__MODULE__, pid}}
      {:error, _reason} = error -> error
    end
  end

  defp gen_server_start(init_arg, nil), do: :gen_server.start_link(__MODULE__, init_arg, [])

  defp gen_server_start(init_arg, name),
    do: :gen_server.start_link({:local, name}, __MODULE__, init_arg, [])

  defp server_config(handler, options) do
    with :ok <- validate_options(options),
         mode = option(options, :mode, :rtu),
         units = option(options, :units, []),
         echo = option(options, :echo, @default_echo),
         silence = option(options, :silence, @default_silence),
         gap = option(options, :gap, default_gap(mode)),
         handler_timeout = option(options, :handler_timeout, @default_handler_timeout),
         backoff = option(options, :backoff, @default_backoff),
         authorize = option(options, :authorize, nil),
         identification = option(options, :identification, nil),
         :ok <- validate_handler(handler),
         :ok <- validate_mode(mode),
         :ok <- validate_units(units),
         :ok <- validate_echo(echo),
         :ok <- validate_silence(silence),
         :ok <- validate_gap(gap),
         :ok <- validate_handler_timeout(handler_timeout),
         :ok <- validate_backoff(backoff),
         :ok <- validate_authorize(authorize),
         {:ok, identification} <- validate_identification(identification) do
      {:ok,
       %{
         mode: mode,
         units: units,
         echo: echo,
         silence: silence,
         gap: gap,
         handler_timeout: handler_timeout,
         backoff: backoff,
         authorize: authorize,
         identification: identification
       }}
    end
  end

  defp validate_options([]), do: :ok

  defp validate_options([{key, _value} | rest])
       when key in [
              :units,
              :mode,
              :echo,
              :silence,
              :gap,
              :handler_timeout,
              :backoff,
              :authorize,
              :identification,
              :name
            ],
       do: validate_options(rest)

  defp validate_options([option | _rest]), do: {:error, {:invalid_option, option}}

  defp option([], _key, default), do: default
  defp option([{key, value} | _rest], key, _default), do: value
  defp option([_option | rest], key, default), do: option(rest, key, default)

  defp take_handler(options), do: take_handler(options, [])
  defp take_handler([], _rest), do: {:error, :missing_handler_option}

  defp take_handler([{:handler, handler} | rest], reversed),
    do: {:ok, handler, reverse_append(reversed, rest)}

  defp take_handler([option | rest], reversed),
    do: take_handler(rest, [option | reversed])

  defp reverse_append([], tail), do: tail
  defp reverse_append([value | rest], tail), do: reverse_append(rest, [value | tail])

  defp server_name(options) do
    case option(options, :name, nil) do
      nil -> {:ok, nil}
      name when is_atom(name) -> {:ok, name}
      _name -> {:error, :invalid_name_option}
    end
  end

  defp validate_handler(handler) when is_function(handler, 2), do: :ok
  defp validate_handler({module, _argument}) when is_atom(module), do: :ok
  defp validate_handler(_handler), do: {:error, :invalid_handler}

  defp validate_units(units) when is_list(units) and units != [] do
    if valid_units?(units), do: :ok, else: {:error, :invalid_units_option}
  end

  defp validate_units(_units), do: {:error, :invalid_units_option}

  defp valid_units?([]), do: true

  defp valid_units?([unit | rest])
       when is_integer(unit) and unit >= 1 and unit <= 247,
       do: valid_units?(rest)

  defp valid_units?(_units), do: false

  defp validate_echo(value) when is_boolean(value), do: :ok
  defp validate_echo(_value), do: {:error, :invalid_echo_option}

  defp validate_silence(value) when is_integer(value) and value > 0, do: :ok
  defp validate_silence(_value), do: {:error, :invalid_silence_option}

  defp validate_gap(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_gap(_value), do: {:error, :invalid_gap_option}

  defp validate_handler_timeout(:infinity), do: :ok

  defp validate_handler_timeout(value) when is_integer(value) and value > 0,
    do: :ok

  defp validate_handler_timeout(_value), do: {:error, :invalid_handler_timeout_option}

  defp validate_backoff({minimum, maximum})
       when is_integer(minimum) and minimum > 0 and is_integer(maximum) and maximum >= minimum,
       do: :ok

  defp validate_backoff(_value), do: {:error, :invalid_backoff_option}

  defp validate_mode(value) when value in [:rtu, :ascii], do: :ok
  defp validate_mode(_value), do: {:error, :invalid_mode_option}

  defp default_gap(:ascii), do: 0
  defp default_gap(_mode), do: @default_gap_ms

  defp encode_frame(%{mode: :rtu}, unit_id, pdu), do: RTU.encode(unit_id, pdu)

  defp encode_frame(%{mode: :ascii, delimiter: delimiter}, unit_id, pdu),
    do: ASCII.encode(unit_id, pdu, delimiter)

  defp validate_authorize(nil), do: :ok
  defp validate_authorize(value) when is_function(value, 3), do: :ok
  defp validate_authorize(_value), do: {:error, :invalid_authorize_option}

  defp validate_identification(nil), do: {:ok, nil}
  defp validate_identification(objects), do: Identification.validate(objects)
end
