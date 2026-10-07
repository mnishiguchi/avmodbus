defmodule AVModbus.Server.TCP do
  @moduledoc """
  Modbus TCP listener と client connection を管理する server です。

  connection ごとに独立した process が fragmented / concatenated MBAP stream を処理し、
  同じ connection の request は順番に、異なる connection は並行して処理します。
  request semantics、handler isolation、authorization、device identification は
  `AVModbus.Server` と共有します。
  """

  import Bitwise

  alias AVModbus.Server
  alias AVModbus.Server.Identification
  alias AVModbus.TCP, as: Frame

  @behaviour :gen_server

  @default_handler_timeout 10_000
  @default_idle 60_000
  @default_connections 16

  @type server :: pid() | atom()
  @type t :: {__MODULE__, server()}
  @type option ::
          {:port, 0..65_535}
          | {:address, :inet.ip_address()}
          | {:connections, pos_integer()}
          | {:idle, pos_integer() | :infinity}
          | {:handler_timeout, pos_integer() | :infinity}
          | {:allow, nil | [term()]}
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

  @doc "TCP port を listen して server を起動します。"
  @spec start_link(Server.handler(), [option()]) :: {:ok, t()} | {:error, term()}
  def start_link(handler, options \\ [])

  def start_link(handler, options) when is_list(options) do
    with {:ok, name} <- server_name(options),
         {:ok, config} <- server_config(handler, options) do
      start_process(config, name)
    end
  end

  def start_link(_handler, _options), do: {:error, :invalid_options}

  @doc "server が listen している port を返します。port `0` で起動した場合にも利用できます。"
  @spec port(t() | server()) :: 0..65_535
  def port({__MODULE__, server}) when is_pid(server) or is_atom(server),
    do: :gen_server.call(server, :port)

  def port(server) when is_pid(server) or is_atom(server), do: :gen_server.call(server, :port)

  @doc "listener と全 client connection を閉じます。"
  @spec close(t() | server()) :: :ok
  def close({__MODULE__, server}) when is_pid(server) or is_atom(server),
    do: :gen_server.stop(server)

  def close(server) when is_pid(server) or is_atom(server), do: :gen_server.stop(server)

  @doc "listener と connection を閉じて server を停止します。"
  @spec stop(t() | server()) :: :ok
  def stop(server), do: close(server)

  @doc "listener state と現在の connection 数を返します。"
  @spec status(t() | server()) :: {:listening, non_neg_integer()}
  def status({__MODULE__, server}) when is_pid(server) or is_atom(server),
    do: :gen_server.call(server, :status)

  def status(server) when is_pid(server) or is_atom(server),
    do: :gen_server.call(server, :status)

  @impl true
  def init(config) do
    case listen(config) do
      {:ok, listener} ->
        case listener_port(listener) do
          {:ok, port} ->
            send(self(), :start_acceptor)

            {:ok,
             %{
               startup_error: nil,
               listener: listener,
               port: port,
               handler: config.handler,
               authorize: config.authorize,
               identification: config.identification,
               handler_timeout: config.handler_timeout,
               idle: config.idle,
               connections: config.connections,
               allow: config.allow,
               acceptor: nil,
               acceptor_monitor: nil,
               clients: %{}
             }}

          {:error, reason} ->
            :gen_tcp.close(listener)
            {:ok, %{startup_error: reason}}
        end

      {:error, reason} ->
        {:ok, %{startup_error: reason}}
    end
  end

  @impl true
  def handle_call(:startup_result, _from, %{startup_error: nil} = state),
    do: {:reply, :ok, state}

  def handle_call(:startup_result, _from, %{startup_error: reason} = state),
    do: {:reply, {:error, reason}, state}

  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:status, _from, state),
    do: {:reply, {:listening, map_size(state.clients)}, state}

  def handle_call({:admit, address}, _from, state) do
    next = if map_size(state.clients) >= state.connections, do: evict(state, address), else: state
    server = self()

    config = %{
      server: server,
      handler: next.handler,
      authorize: next.authorize,
      identification: next.identification,
      handler_timeout: next.handler_timeout,
      idle: next.idle
    }

    {pid, monitor} = :erlang.spawn_monitor(fn -> connection(config) end)
    client = %{monitor: monitor, address: address, last_at: monotonic_time()}
    {:reply, {:ok, pid}, %{next | clients: Map.put(next.clients, pid, client)}}
  end

  def handle_call({:activity, pid, at}, _from, state) do
    case Map.fetch(state.clients, pid) do
      {:ok, client} ->
        clients = Map.put(state.clients, pid, %{client | last_at: at})
        {:reply, :ok, %{state | clients: clients}}

      :error ->
        {:reply, {:error, :closed}, state}
    end
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :unsupported_call}, state}

  @impl true
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(:start_acceptor, %{acceptor: nil} = state) do
    server = self()
    listener = state.listener
    allow = state.allow
    {acceptor, monitor} = :erlang.spawn_monitor(fn -> accept(server, listener, allow) end)
    {:noreply, %{state | acceptor: acceptor, acceptor_monitor: monitor}}
  end

  def handle_info(
        {:DOWN, monitor, :process, acceptor, reason},
        %{acceptor: acceptor, acceptor_monitor: monitor} = state
      ) do
    {:stop, reason, state}
  end

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state),
    do: {:noreply, %{state | clients: Map.delete(state.clients, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{startup_error: reason}) when not is_nil(reason), do: :ok

  def terminate(_reason, state) do
    _result = :gen_tcp.close(state.listener)
    if state.acceptor, do: Process.exit(state.acceptor, :kill)
    kill_clients(Map.to_list(state.clients))
    :ok
  end

  @doc false
  def allowed?(_address, nil), do: true
  def allowed?(address, allow) when is_list(allow), do: allowed_in?(plain(address), allow)
  def allowed?(_address, _allow), do: false

  @doc false
  def victim([], _new_address), do: nil

  def victim(rows, new_address) when is_list(rows) do
    groups = group_rows(rows, %{})
    most = greatest_held(Map.to_list(groups), new_address, 0)

    selected =
      case Map.fetch(groups, new_address) do
        {:ok, own} ->
          if held(new_address, own, new_address) == most,
            do: own,
            else: oldest_tied_group(Map.to_list(groups), new_address, most, nil)

        :error ->
          oldest_tied_group(Map.to_list(groups), new_address, most, nil)
      end

    case oldest_row(selected) do
      {pid, _at} -> pid
      nil -> nil
    end
  end

  defp start_process(config, name) do
    case gen_server_start(config, name) do
      {:ok, pid} ->
        case :gen_server.call(pid, :startup_result) do
          :ok ->
            {:ok, {__MODULE__, pid}}

          {:error, _reason} = error ->
            :gen_server.stop(pid)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp gen_server_start(config, nil), do: :gen_server.start_link(__MODULE__, config, [])

  defp gen_server_start(config, name),
    do: :gen_server.start_link({:local, name}, __MODULE__, config, [])

  defp listen(config) do
    family = if tuple_size(config.address) == 8, do: [:inet6], else: []

    options =
      family ++
        [
          :binary,
          active: true,
          reuseaddr: true,
          ip: config.address
        ]

    :gen_tcp.listen(config.port, options)
  end

  defp listener_port(listener) do
    case :inet.port(listener) do
      port when is_integer(port) -> {:ok, port}
      {:ok, port} when is_integer(port) -> {:ok, port}
      {:error, _reason} = error -> error
      other -> {:error, {:inet_port, other}}
    end
  end

  defp accept(server, listener, allow) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        hand_over(server, socket, allow)
        accept(server, listener, allow)

      {:error, :closed} ->
        :ok

      {:error, reason} when reason in [:emfile, :enfile, :enobufs, :enomem, :system_limit] ->
        Process.sleep(10)
        accept(server, listener, allow)

      {:error, _reason} ->
        accept(server, listener, allow)
    end
  end

  defp hand_over(server, socket, allow) do
    with {:ok, {address, _port}} <- :inet.peername(socket),
         true <- allowed?(address, allow),
         {:ok, pid} <- admit(server, address),
         :ok <- :gen_tcp.controlling_process(socket, pid) do
      send(pid, {:socket, socket})
      forward_socket_messages(socket, pid)
    else
      _not_allowed_or_stopped -> :gen_tcp.close(socket)
    end
  end

  defp admit(server, address) do
    try do
      :gen_server.call(server, {:admit, address}, :infinity)
    catch
      :exit, _reason -> {:error, :closed}
    end
  end

  defp forward_socket_messages(socket, pid) do
    receive do
      {:tcp, ^socket, _data} = message ->
        send(pid, message)
        forward_socket_messages(socket, pid)

      {:tcp_closed, ^socket} = message ->
        send(pid, message)

      {:tcp_error, ^socket, _reason} = message ->
        send(pid, message)
    after
      0 -> :ok
    end
  end

  defp connection(config) do
    receive do
      {:socket, socket} ->
        loop(config, socket, <<>>, deadline(config.idle))
        :gen_tcp.close(socket)
    after
      5_000 -> :ok
    end
  end

  defp loop(config, socket, buffer, :infinity) do
    receive do
      {:tcp, ^socket, data} when is_binary(data) ->
        continue(config, socket, <<buffer::binary, data::binary>>, :infinity)

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _reason} ->
        :ok
    end
  end

  defp loop(config, socket, buffer, deadline_at) do
    receive do
      {:tcp, ^socket, data} when is_binary(data) ->
        continue(config, socket, <<buffer::binary, data::binary>>, deadline_at)

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _reason} ->
        :ok
    after
      wait(deadline_at) -> :ok
    end
  end

  defp continue(config, socket, buffer, deadline_at) do
    case frames(config, socket, buffer, deadline_at) do
      {:ok, rest, next_deadline} -> loop(config, socket, rest, next_deadline)
      :close -> :ok
    end
  end

  defp frames(config, socket, buffer, deadline_at) do
    case Frame.decode(buffer) do
      {:ok, transaction_id, unit_id, pdu, rest} ->
        case touch(config.server) do
          :ok ->
            policy = %{
              authorize: config.authorize,
              identification: config.identification,
              role: nil
            }

            case Server.respond(config.handler, unit_id, pdu, config.handler_timeout, policy) do
              {:ok, response_pdu} ->
                {:ok, response} = Frame.encode(transaction_id, unit_id, response_pdu)

                case :gen_tcp.send(socket, response) do
                  :ok -> frames(config, socket, rest, deadline(config.idle))
                  {:error, _reason} -> :close
                  _other -> :close
                end

              :ignore ->
                frames(config, socket, rest, deadline(config.idle))
            end

          {:error, :closed} ->
            :close
        end

      {:discard, rest} ->
        frames(config, socket, rest, deadline_at)

      :more ->
        {:ok, buffer, deadline_at}

      {:error, _reason} ->
        :close
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(idle), do: monotonic_ms() + idle
  defp wait(deadline_at), do: max(deadline_at - monotonic_ms(), 0)

  defp touch(server) do
    try do
      :gen_server.call(server, {:activity, self(), monotonic_time()}, :infinity)
    catch
      :exit, _reason -> {:error, :closed}
    end
  end

  defp evict(state, new_address) do
    rows = client_rows(Map.to_list(state.clients), [])

    case victim(rows, new_address) do
      nil ->
        state

      pid ->
        case Map.fetch(state.clients, pid) do
          :error ->
            state

          {:ok, client} ->
            Process.exit(pid, :kill)
            :erlang.demonitor(client.monitor, [:flush])
            %{state | clients: Map.delete(state.clients, pid)}
        end
    end
  end

  defp client_rows([], rows), do: rows

  defp client_rows([{pid, client} | rest], rows),
    do: client_rows(rest, [{pid, client.last_at, client.address} | rows])

  defp group_rows([], groups), do: groups

  defp group_rows([{pid, at, address} | rest], groups) do
    group = Map.get(groups, address, [])
    group_rows(rest, Map.put(groups, address, [{pid, at} | group]))
  end

  defp greatest_held([], _new_address, greatest), do: greatest

  defp greatest_held([{address, rows} | rest], new_address, greatest) do
    count = held(address, rows, new_address)
    greatest_held(rest, new_address, max(count, greatest))
  end

  defp held(address, rows, new_address),
    do: list_length(rows, 0) + if(address == new_address, do: 1, else: 0)

  defp oldest_tied_group([], _new_address, _most, selected), do: selected

  defp oldest_tied_group([{address, rows} | rest], new_address, most, selected) do
    next =
      if held(address, rows, new_address) == most and older_group?(rows, selected),
        do: rows,
        else: selected

    oldest_tied_group(rest, new_address, most, next)
  end

  defp older_group?(_rows, nil), do: true

  defp older_group?(rows, selected) do
    {_pid, oldest} = oldest_row(rows)
    {_selected_pid, selected_oldest} = oldest_row(selected)
    oldest < selected_oldest
  end

  defp oldest_row([]), do: nil
  defp oldest_row([row | rest]), do: oldest_row(rest, row)
  defp oldest_row([], oldest), do: oldest

  defp oldest_row([{_pid, at} = row | rest], {_oldest_pid, oldest_at}) when at < oldest_at,
    do: oldest_row(rest, row)

  defp oldest_row([_row | rest], oldest), do: oldest_row(rest, oldest)

  defp list_length([], result), do: result
  defp list_length([_value | rest], result), do: list_length(rest, result + 1)

  defp kill_clients([]), do: :ok

  defp kill_clients([{pid, _client} | rest]) do
    Process.exit(pid, :kill)
    kill_clients(rest)
  end

  defp allowed_in?(_address, []), do: false

  defp allowed_in?(address, [{network, bits} | rest])
       when is_tuple(network) and is_integer(bits) do
    if same_net?(address, plain(network), bits),
      do: true,
      else: allowed_in?(address, rest)
  end

  defp allowed_in?(address, [network | rest]) when is_tuple(network) do
    bits = if tuple_size(network) == 4, do: 32, else: 128

    if same_net?(address, plain(network), bits),
      do: true,
      else: allowed_in?(address, rest)
  end

  defp allowed_in?(address, [_invalid | rest]), do: allowed_in?(address, rest)

  defp plain({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)}

  defp plain(address), do: address

  defp same_net?(address, network, bits)
       when tuple_size(address) == tuple_size(network) and bits >= 0 do
    width = if tuple_size(network) == 4, do: 32, else: 128

    if bits <= width do
      shift = width - bits

      address_number(address, 0, tuple_size(address), 0) >>> shift ==
        address_number(network, 0, tuple_size(network), 0) >>> shift
    else
      false
    end
  end

  defp same_net?(_address, _network, _bits), do: false

  defp address_number(_address, index, size, result) when index == size, do: result

  defp address_number(address, index, size, result) do
    part_size = if size == 4, do: 8, else: 16
    address_number(address, index + 1, size, result <<< part_size ||| elem(address, index))
  end

  defp server_config(handler, options) do
    with :ok <- validate_options(options),
         port = option(options, :port, 502),
         address = option(options, :address, {0, 0, 0, 0}),
         connections = option(options, :connections, @default_connections),
         idle = option(options, :idle, @default_idle),
         handler_timeout = option(options, :handler_timeout, @default_handler_timeout),
         allow = option(options, :allow, nil),
         authorize = option(options, :authorize, nil),
         identification = option(options, :identification, nil),
         :ok <- validate_handler(handler),
         :ok <- validate_port(port),
         :ok <- validate_address(address),
         :ok <- validate_connections(connections),
         :ok <- validate_idle(idle),
         :ok <- validate_handler_timeout(handler_timeout),
         :ok <- validate_allow(allow),
         :ok <- validate_authorize(authorize),
         {:ok, identification} <- validate_identification(identification) do
      {:ok,
       %{
         handler: handler,
         port: port,
         address: address,
         connections: connections,
         idle: idle,
         handler_timeout: handler_timeout,
         allow: allow,
         authorize: authorize,
         identification: identification
       }}
    end
  end

  defp validate_options([]), do: :ok

  defp validate_options([{key, _value} | _rest]) when key in [:tls, :ssl],
    do: {:error, :tls_not_supported}

  defp validate_options([{key, _value} | rest])
       when key in [
              :port,
              :address,
              :connections,
              :idle,
              :handler_timeout,
              :allow,
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

  defp validate_port(port) when is_integer(port) and port >= 0 and port <= 65_535, do: :ok
  defp validate_port(_port), do: {:error, :invalid_port_option}

  defp validate_address(address) when is_tuple(address) and tuple_size(address) in [4, 8] do
    if valid_address_parts?(address, 0, tuple_size(address)),
      do: :ok,
      else: {:error, :invalid_address_option}
  end

  defp validate_address(_address), do: {:error, :invalid_address_option}

  defp valid_address_parts?(_address, index, size) when index == size, do: true

  defp valid_address_parts?(address, index, size) do
    limit = if size == 4, do: 255, else: 65_535
    part = elem(address, index)

    is_integer(part) and part >= 0 and part <= limit and
      valid_address_parts?(address, index + 1, size)
  end

  defp validate_connections(value) when is_integer(value) and value > 0, do: :ok
  defp validate_connections(_value), do: {:error, :invalid_connections_option}

  defp validate_idle(:infinity), do: :ok
  defp validate_idle(value) when is_integer(value) and value > 0, do: :ok
  defp validate_idle(_value), do: {:error, :invalid_idle_option}

  defp validate_handler_timeout(:infinity), do: :ok
  defp validate_handler_timeout(value) when is_integer(value) and value > 0, do: :ok
  defp validate_handler_timeout(_value), do: {:error, :invalid_handler_timeout_option}

  defp validate_allow(nil), do: :ok
  defp validate_allow(allow) when is_list(allow), do: validate_allow_entries(allow)
  defp validate_allow(_allow), do: {:error, :invalid_allow_option}

  defp validate_allow_entries([]), do: :ok

  defp validate_allow_entries([{address, bits} | rest])
       when is_tuple(address) and is_integer(bits) do
    width = if tuple_size(address) == 4, do: 32, else: 128

    with :ok <- validate_address(address),
         true <- bits >= 0 and bits <= width do
      validate_allow_entries(rest)
    else
      _error -> {:error, :invalid_allow_option}
    end
  end

  defp validate_allow_entries([address | rest]) when is_tuple(address) do
    case validate_address(address) do
      :ok -> validate_allow_entries(rest)
      {:error, _reason} -> {:error, :invalid_allow_option}
    end
  end

  defp validate_allow_entries(_invalid), do: {:error, :invalid_allow_option}

  defp validate_authorize(nil), do: :ok
  defp validate_authorize(authorize) when is_function(authorize, 3), do: :ok
  defp validate_authorize(_authorize), do: {:error, :invalid_authorize_option}

  defp validate_identification(nil), do: {:ok, nil}
  defp validate_identification(objects), do: Identification.validate(objects)

  defp monotonic_ms, do: :erlang.monotonic_time(:millisecond)
  defp monotonic_time, do: :erlang.monotonic_time()
end
