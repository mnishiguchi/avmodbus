defmodule AVModbus.Server do
  @moduledoc """
  transport-independent な Modbus server request processor です。

  handler は 2-argument function または `{module, argument}` tuple で指定します。
  module handler は `handle_request/3` を実装し、unit id と decoded request を受け取ります。

  `start_link/1` は統一 startup facade として transport-specific managed server に委譲します。
  request processor 自身は UART / socket を所有せず、serial / TCP server loop が framing と
  lifecycle を担当して complete request PDU を `respond/3` に渡します。

  AtomVM の SSL API で mutual-authenticated server を構築できるようになるまでは、TLS option を
  `{:error, :tls_not_supported}` で fail closed します。
  """

  alias AVModbus.PDU
  alias AVModbus.Server.{ASCII, RTU, TCP}
  alias AVModbus.Server.Identification

  @default_handler_timeout 10_000

  @type unit_id :: 0..255
  @type handler :: (unit_id(), PDU.request() -> PDU.result()) | {module(), term()}
  @type authorize :: (term(), unit_id(), PDU.request() -> boolean())
  @type policy :: %{
          optional(:authorize) => authorize() | nil,
          optional(:identification) => Identification.objects() | nil,
          optional(:role) => term()
        }

  @callback handle_request(unit_id(), PDU.request(), term()) :: PDU.result()

  @doc false
  def child_spec(options) when is_list(options) do
    %{
      id: option(options, :name, __MODULE__),
      start: {__MODULE__, :start_link, [options]}
    }
  end

  @doc """
  managed Modbus server を起動し、raw PID を返します。

  transport 指定がなければ TCP server を起動します。serial server は
  `transport: :rtu` / `transport: :ascii`、または `rtu: true` / `ascii: true` で選択します。
  `:handler` と選択した transport module の options を同じ list に指定します。
  `transport: :tls`、`tls:`、`ssl:` は現在 `{:error, :tls_not_supported}` を返します。
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(options) when is_list(options) do
    with :ok <- reject_tls(options),
         {:ok, transport, server_options} <- route(options) do
      transport.start_supervised(server_options)
    end
  end

  def start_link(_options), do: {:error, :invalid_options}

  @doc "managed server の現在の transport state を返します。"
  @spec status(pid() | atom() | tuple()) :: term()
  def status(server), do: :gen_server.call(server_ref(server), :status)

  @doc "TCP server が listen している port を返します。"
  @spec port(pid() | atom() | tuple()) :: 0..65_535 | {:error, term()}
  def port(server), do: :gen_server.call(server_ref(server), :port)

  @doc "managed server を停止し、所有する listener または UART を閉じます。"
  @spec stop(pid() | atom() | tuple()) :: :ok
  def stop(server), do: :gen_server.stop(server_ref(server))

  @doc "`stop/1` の互換 alias です。"
  @spec close(pid() | atom() | tuple()) :: :ok
  def close(server), do: stop(server)

  @doc """
  request PDU を decode し、handler を呼び出して response PDU を encode します。

  malformed request は Modbus exception response に変換します。empty PDU や public request range 外の
  function byte は valid response function を導けないため無視します。
  """
  @spec respond(handler(), unit_id(), binary()) :: {:ok, binary()} | :ignore
  def respond(handler, unit_id, pdu),
    do: respond(handler, unit_id, pdu, @default_handler_timeout)

  @doc """
  `respond/3` に handler execution timeout を追加した variant です。

  handler は monitored process で実行され、crash / timeout は transport process を落とさず
  `server_device_failure` response に変換されます。
  """
  @spec respond(handler(), unit_id(), binary(), pos_integer() | :infinity) ::
          {:ok, binary()} | :ignore
  def respond(_handler, _unit_id, <<>>, _handler_timeout), do: :ignore

  def respond(handler, unit_id, <<function, _rest::binary>> = pdu, handler_timeout)
      when is_integer(unit_id) and unit_id >= 0 and unit_id <= 255 do
    case PDU.decode_request(pdu) do
      {:ok, request} -> respond_to_request(handler, unit_id, request, handler_timeout)
      {:error, exception} -> encode_exception(function, exception)
    end
  end

  def respond(_handler, _unit_id, _pdu, _handler_timeout), do: :ignore

  @doc """
  `respond/4` に authorization、peer role、device identification policy を追加した variant です。

  policy key は `:authorize`、`:role`、`:identification` です。authorization と response generation は
  同じ handler timeout の中で 1 つの isolated process として実行します。
  """
  @spec respond(handler(), unit_id(), binary(), pos_integer() | :infinity, policy()) ::
          {:ok, binary()} | :ignore
  def respond(_handler, _unit_id, <<>>, _handler_timeout, _policy), do: :ignore

  def respond(handler, unit_id, <<function, _rest::binary>> = pdu, handler_timeout, policy)
      when is_integer(unit_id) and unit_id >= 0 and unit_id <= 255 and is_map(policy) do
    case PDU.decode_request(pdu) do
      {:ok, request} ->
        result =
          timed(
            fn -> policy_result(handler, unit_id, request, policy) end,
            handler_timeout
          )

        encode_result(request, result)

      {:error, exception} ->
        encode_exception(function, exception)
    end
  end

  def respond(_handler, _unit_id, _pdu, _handler_timeout, _policy), do: :ignore

  defp route(options) do
    with {:ok, markers} <- transport_markers(options, []),
         {:ok, transport} <- selected_transport(option(options, :transport, nil), markers) do
      {:ok, transport_module(transport), remove_transport_options(options, [])}
    end
  end

  defp reject_tls([]), do: :ok

  defp reject_tls([{:transport, :tls} | _rest]), do: {:error, :tls_not_supported}

  defp reject_tls([{key, _value} | _rest]) when key in [:tls, :ssl],
    do: {:error, :tls_not_supported}

  defp reject_tls([_option | rest]), do: reject_tls(rest)

  defp transport_markers([], markers), do: {:ok, markers}

  defp transport_markers([{key, true} | rest], markers)
       when key in [:tcp, :rtu, :ascii],
       do: transport_markers(rest, [key | markers])

  defp transport_markers([{key, _value} | _rest], _markers)
       when key in [:tcp, :rtu, :ascii],
       do: {:error, invalid_transport_marker(key)}

  defp transport_markers([_option | rest], markers), do: transport_markers(rest, markers)

  defp selected_transport(nil, []), do: {:ok, :tcp}
  defp selected_transport(nil, [transport]), do: {:ok, transport}

  defp selected_transport(transport, []) when transport in [:tcp, :rtu, :ascii],
    do: {:ok, transport}

  defp selected_transport(nil, _multiple), do: {:error, :multiple_transport_options}

  defp selected_transport(transport, _markers) when transport in [:tcp, :rtu, :ascii],
    do: {:error, :multiple_transport_options}

  defp selected_transport(_transport, _markers), do: {:error, :invalid_transport_option}

  defp transport_module(:tcp), do: TCP
  defp transport_module(:rtu), do: RTU
  defp transport_module(:ascii), do: ASCII

  defp invalid_transport_marker(:tcp), do: :invalid_tcp_option
  defp invalid_transport_marker(:rtu), do: :invalid_rtu_option
  defp invalid_transport_marker(:ascii), do: :invalid_ascii_option

  defp remove_transport_options([], reversed), do: reverse(reversed, [])

  defp remove_transport_options([{key, _value} | rest], reversed)
       when key in [:transport, :tcp, :rtu, :ascii],
       do: remove_transport_options(rest, reversed)

  defp remove_transport_options([option | rest], reversed),
    do: remove_transport_options(rest, [option | reversed])

  defp server_ref({module, server})
       when module in [TCP, RTU, ASCII] and (is_pid(server) or is_atom(server)),
       do: server

  defp server_ref(server), do: server

  defp option([], _key, default), do: default
  defp option([{key, value} | _rest], key, _default), do: value
  defp option([_option | rest], key, default), do: option(rest, key, default)

  defp reverse([], result), do: result
  defp reverse([value | rest], result), do: reverse(rest, [value | result])

  @doc """
  transport 自身が処理する request に対して authorization を確認します。

  callback がない場合は許可します。callback crash、falsey result、timeout は拒否として扱います。
  """
  @spec allowed?(authorize() | nil, term(), unit_id(), PDU.request(), pos_integer() | :infinity) ::
          boolean()
  def allowed?(authorize, role, unit_id, request, handler_timeout) do
    timed(fn -> authorized?(authorize, role, unit_id, request) end, handler_timeout) == true
  end

  @doc "wire response を encode せず server handler を呼び出します。"
  @spec handle_request(handler(), unit_id(), PDU.request()) :: PDU.result()
  def handle_request(handler, unit_id, request),
    do: handle_request(handler, unit_id, request, @default_handler_timeout)

  @doc "handler を isolated process で timeout 付き実行します。"
  @spec handle_request(handler(), unit_id(), PDU.request(), pos_integer() | :infinity) ::
          PDU.result()
  def handle_request(handler, unit_id, request, handler_timeout) do
    timed(fn -> invoke_handler(handler, unit_id, request) end, handler_timeout)
  end

  defp timed(fun, handler_timeout)
       when handler_timeout == :infinity or
              (is_integer(handler_timeout) and handler_timeout > 0) do
    caller = self()
    reply_ref = make_ref()

    {pid, monitor_ref} =
      :erlang.spawn_monitor(fn ->
        result = safe_call(fun)
        send(caller, {reply_ref, result})
      end)

    await(pid, monitor_ref, reply_ref, handler_timeout)
  end

  defp timed(_fun, _handler_timeout), do: {:error, {:exception, :server_device_failure}}

  defp await(pid, monitor_ref, reply_ref, :infinity) do
    receive do
      {^reply_ref, result} ->
        :erlang.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:error, {:exception, :server_device_failure}}
    end
  end

  defp await(pid, monitor_ref, reply_ref, handler_timeout) do
    receive do
      {^reply_ref, result} ->
        :erlang.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:error, {:exception, :server_device_failure}}
    after
      handler_timeout ->
        :erlang.exit(pid, :kill)
        :erlang.demonitor(monitor_ref, [:flush])

        receive do
          {^reply_ref, result} -> result
        after
          0 -> {:error, {:exception, :server_device_failure}}
        end
    end
  end

  defp safe_call(fun) do
    fun.()
  catch
    _kind, _reason -> {:error, {:exception, :server_device_failure}}
  end

  defp invoke_handler(handler, unit_id, request) do
    handler
    |> call_handler(unit_id, request)
    |> normalize_result()
  catch
    _kind, _reason -> {:error, {:exception, :server_device_failure}}
  end

  defp policy_result(handler, unit_id, request, policy) do
    authorize = Map.get(policy, :authorize)
    role = Map.get(policy, :role)
    identification = Map.get(policy, :identification)

    cond do
      not authorized?(authorize, role, unit_id, request) ->
        {:error, {:exception, :illegal_function}}

      not is_nil(identification) and
          match?({:read_device_identification, _category, _object_id}, request) ->
        Identification.answer(identification, request)

      true ->
        invoke_handler(handler, unit_id, request)
    end
  end

  defp authorized?(nil, _role, _unit_id, _request), do: true

  defp authorized?(authorize, role, unit_id, request) when is_function(authorize, 3) do
    authorize.(role, unit_id, request) == true
  catch
    _kind, _reason -> false
  end

  defp authorized?(_authorize, _role, _unit_id, _request), do: false

  defp respond_to_request(handler, unit_id, request, handler_timeout) do
    result = handle_request(handler, unit_id, request, handler_timeout)

    encode_result(request, result)
  end

  defp encode_result(request, result) do
    case PDU.encode_response(request, result) do
      {:ok, response} -> {:ok, response}
      {:error, _reason} -> encode_request_exception(request, :server_device_failure)
    end
  end

  defp call_handler({module, argument}, unit_id, request) when is_atom(module),
    do: module.handle_request(unit_id, request, argument)

  defp call_handler(handler, unit_id, request) when is_function(handler, 2),
    do: handler.(unit_id, request)

  defp call_handler(_handler, _unit_id, _request),
    do: {:error, {:exception, :server_device_failure}}

  defp normalize_result({:error, :timeout}),
    do: {:error, {:exception, :gateway_target_device_failed_to_respond}}

  defp normalize_result({:error, :closed}),
    do: {:error, {:exception, :gateway_path_unavailable}}

  defp normalize_result(result), do: result

  defp encode_request_exception(request, exception) do
    case PDU.function(request) do
      {:ok, function} -> encode_exception(function, exception)
      {:error, _reason} -> :ignore
    end
  end

  defp encode_exception(function, exception) do
    case PDU.encode_exception(function, exception) do
      {:ok, response} -> {:ok, response}
      {:error, _reason} -> :ignore
    end
  end
end
