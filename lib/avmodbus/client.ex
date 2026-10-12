defmodule AVModbus.Client do
  @moduledoc """
  serial bus または TCP connection を所有する managed Modbus client です。

  通常の serial application では `start_link/1` で process が UART を所有し、
  request を順番に処理します。low-level transaction API は host-side tests や
  UART ownership を application 側で管理する用途に利用できます。

  serial client では active transaction を 1 件に制限し、送信待ちは `:max_queue` で制限します。
  queue saturation は `{:error, :queue_full}` を返します。unit `0` への write は broadcast として扱い、
  response を読まず configured turnaround delay の後に transaction を完了します。
  TCP の unit id は `0..255` を routing identifier として扱います。

  `start_link(transport: :tcp, host: host)` では複数 request を transaction id で照合しながら並行送信する
  Modbus TCP client を起動します。wire 上の request は `:max_pending`、送信待ちは
  `:max_queue` で制限し、queue saturation は `{:error, :queue_full}` を返します。

  child specification を実装しているため supervision tree に直接追加できます。
  supervised child の raw PID、`:name` で登録した atom、`start_link` が返す tagged handle の
  いずれも全 managed client API で利用できます。

  request function の最後の引数には `timeout:`、`retries:`、`backoff:` の keyword options を
  指定できます。retry は明示的に指定した
  idempotent read にだけ適用され、write は再送しません。

  managed client の `:timeout` option は request ごとの既定 deadline を指定します。
  request 側の timeout を省略するとこの値を使い、明示した `timeout:` は client の既定値を
  上書きします。

  現在の AtomVM SSL API は Modbus/TCP Security が要求する mutual authentication を提供できないため、
  `tls:` または `ssl:` option は `{:error, :tls_not_supported}` を返します。
  """

  alias AVModbus.{ASCII, PDU, RTU, Serial, UART}

  @default_timeout 1_000
  @default_max_queue 64
  @default_echo Application.compile_env(:avmodbus, :modbus_echo, false)
  @default_turnaround Application.compile_env(:avmodbus, :modbus_broadcast_turnaround_ms, 100)
  @default_backoff Application.compile_env(
                     :avmodbus,
                     :modbus_reconnect_backoff,
                     {100, 5_000}
                   )
  @max_rtu_frame_size 256
  @behaviour :gen_server

  @type server :: pid() | atom()
  @opaque t :: {__MODULE__, server()} | {__MODULE__, server(), :tcp}
  @type option ::
          {:transport, :rtu | :ascii | :tcp}
          | {:host, term()}
          | {:echo, boolean()}
          | {:turnaround, pos_integer()}
          | {:silence, pos_integer()}
          | {:gap, non_neg_integer()}
          | {:serial, keyword()}
          | {:backoff, {pos_integer(), pos_integer()}}
          | {:port, 1..65_535}
          | {:max_pending, 1..65_536}
          | {:max_queue, non_neg_integer() | :infinity}
          | {:check_unit, boolean()}
          | {:connect_timeout, pos_integer()}
          | {:timeout, pos_integer()}
          | {:name, atom()}
  @type retry_option ::
          {:timeout, non_neg_integer()}
          | {:retries, non_neg_integer()}
          | {:backoff, {pos_integer(), pos_integer()}}
  @type async_option :: {:timeout, non_neg_integer()} | {:to, pid()}
  @type request_result :: :ok | {:ok, term()} | {:error, term()}
  @type device_identification_category :: :basic | :regular | :extended
  @type device_identification_option ::
          retry_option() | {:category, device_identification_category()}

  @doc false
  def child_spec(options) when is_list(options) do
    %{
      id: option(options, :name, __MODULE__),
      start: {__MODULE__, :start_supervised, [options]}
    }
  end

  @doc false
  def start_supervised(options) when is_list(options) do
    case start_link(options) do
      {:ok, {__MODULE__, pid}} -> {:ok, pid}
      {:ok, {__MODULE__, pid, :tcp}} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  def start_supervised(_options), do: {:error, :invalid_options}

  @doc """
  transport を指定しないため `{:error, :missing_transport_option}` を返します。

  `start_link(transport: :rtu)`、`start_link(transport: :ascii)`、または
  `start_link(transport: :tcp, host: host)` を使用してください。
  """
  @spec start_link() :: {:ok, t()} | {:error, term()}
  def start_link, do: {:error, :missing_transport_option}

  @doc """
  client option を使って configured UART を開き、その lifecycle を所有します。

  `:transport` は必須で、`:rtu`、`:ascii`、`:tcp` のいずれかを指定します。
  TCP では `:host` も必須です。serial の主な option は adapter echo を除去する `:echo`、
  broadcast 後の `:turnaround`、送信前の `:gap`、unknown-length response を区切る
  `:silence`、instance UART 設定の `:serial`、待機 request 上限の `:max_queue`、request の既定
  deadline を指定する `:timeout`、UART reopen delay を指定する `:backoff` (`{first, maximum}`) です。
  時間指定は millisecond 単位です。
  """
  @spec start_link([option()] | term()) :: {:ok, t()} | {:error, term()}
  def start_link(options_or_uart)

  def start_link(options) when is_list(options) do
    with :ok <- reject_tls(options),
         {:ok, name} <- client_name(options),
         {:ok, transport} <- required_transport(options) do
      case transport do
        :tcp ->
          with {:ok, host} <- required_host(options) do
            start_tcp_server(host, options, name)
          end

        _serial_transport ->
          with {:ok, config} <- client_config(options),
               :ok <- UART.validate_options(config.serial) do
            start_server({:open, UART, config}, name)
          end
      end
    end
  end

  def start_link(_options), do: {:error, :invalid_options}

  @doc """
  すでに open 済みの UART を使って managed client を起動します。

  UART の ownership は呼び出し側に残り、client は停止時や transport failure 時に close / reopen
  しません。library に lifecycle を管理させる場合は `start_link/1` の `serial:` option を使います。
  """
  @spec start_link(term(), [option()] | term()) :: {:ok, t()} | {:error, term()}
  def start_link(uart_or_transport, options_or_uart)

  @doc false
  def start_link(transport, options) when is_atom(transport) and is_list(options) do
    with :ok <- reject_tls(options),
         {:ok, name} <- client_name(options),
         {:ok, config} <- managed_client_config(options) do
      start_server({:open, transport, config}, name)
    end
  end

  def start_link(uart, options) when is_list(options) do
    with :ok <- reject_tls(options),
         {:ok, name} <- client_name(options),
         {:ok, config} <- managed_client_config(options) do
      start_server({:ready, UART, uart, false, config}, name)
    end
  end

  def start_link(_uart_or_transport, _options_or_uart), do: {:error, :invalid_options}

  @doc false
  def start_link(transport, uart, options) when is_atom(transport) and is_list(options) do
    with :ok <- reject_tls(options),
         {:ok, name} <- client_name(options),
         {:ok, config} <- managed_client_config(options) do
      start_server({:ready, transport, uart, false, config}, name)
    end
  end

  def start_link(_transport, _uart, _options), do: {:error, :invalid_options}

  @doc "managed client を停止し、connection または所有する UART を閉じます。"
  @spec stop(t() | server()) :: :ok
  def stop({__MODULE__, server}) when is_pid(server) or is_atom(server),
    do: :gen_server.stop(server)

  def stop({__MODULE__, server, :tcp}) when is_pid(server) or is_atom(server),
    do: :gen_server.stop(server)

  def stop(server) when is_pid(server) or is_atom(server), do: :gen_server.stop(server)

  @doc "managed client の現在の connection state を返します。"
  @spec status(t() | server()) :: :connected | :connecting | {:disconnected, term()}
  def status({__MODULE__, server}) when is_pid(server) or is_atom(server),
    do: :gen_server.call(server, :status)

  def status({__MODULE__, server, :tcp}) when is_pid(server) or is_atom(server),
    do: :gen_server.call(server, :status)

  def status(server) when is_pid(server) or is_atom(server),
    do: :gen_server.call(server, :status)

  @doc "Coil を読み取ります。"
  @spec read_coils(term(), 0..255, AVModbus.address(), pos_integer(), [retry_option()]) ::
          request_result()
  def read_coils(client, unit_id, address, quantity, options \\ []) do
    request(client, unit_id, {:read_coils, address, quantity}, options)
  end

  @doc "Discrete Input を読み取ります。"
  @spec read_discrete_inputs(
          term(),
          0..255,
          AVModbus.address(),
          pos_integer(),
          [retry_option()]
        ) :: request_result()
  def read_discrete_inputs(client, unit_id, address, quantity, options \\ []) do
    request(client, unit_id, {:read_discrete_inputs, address, quantity}, options)
  end

  @doc "Holding Register を読み取ります。"
  @spec read_holding_registers(
          term(),
          0..255,
          AVModbus.address(),
          pos_integer(),
          [retry_option()]
        ) :: request_result()
  def read_holding_registers(client, unit_id, address, quantity, options \\ []) do
    request(client, unit_id, {:read_holding_registers, address, quantity}, options)
  end

  @doc "Input Register を読み取ります。"
  @spec read_input_registers(
          term(),
          0..255,
          AVModbus.address(),
          pos_integer(),
          [retry_option()]
        ) :: request_result()
  def read_input_registers(client, unit_id, address, quantity, options \\ []) do
    request(client, unit_id, {:read_input_registers, address, quantity}, options)
  end

  @doc "1 個の Coil を書き込みます。"
  @spec write_single_coil(
          term(),
          0..255,
          AVModbus.address(),
          boolean(),
          [retry_option()]
        ) :: request_result()
  def write_single_coil(client, unit_id, address, value, options \\ []) do
    request(client, unit_id, {:write_single_coil, address, value}, options)
  end

  @doc "1 個の Holding Register を書き込みます。"
  @spec write_single_register(
          term(),
          0..255,
          AVModbus.address(),
          AVModbus.word(),
          [retry_option()]
        ) :: request_result()
  def write_single_register(client, unit_id, address, value, options \\ []) do
    request(client, unit_id, {:write_single_register, address, value}, options)
  end

  @doc "server の exception status を読み取ります。"
  @spec read_exception_status(term(), 0..255, [retry_option()]) :: request_result()
  def read_exception_status(client, unit_id, options \\ []) do
    request(client, unit_id, :read_exception_status, options)
  end

  @doc "diagnostics sub-function を実行します。"
  @spec diagnostics(term(), 0..255, AVModbus.word(), [AVModbus.word()], [retry_option()]) ::
          request_result()
  def diagnostics(client, unit_id, sub_function, data, options \\ []) do
    request(client, unit_id, {:diagnostics, sub_function, data}, options)
  end

  @doc "communication event counter を読み取ります。"
  @spec get_comm_event_counter(term(), 0..255, [retry_option()]) :: request_result()
  def get_comm_event_counter(client, unit_id, options \\ []) do
    request(client, unit_id, :get_comm_event_counter, options)
  end

  @doc "communication event log を読み取ります。"
  @spec get_comm_event_log(term(), 0..255, [retry_option()]) :: request_result()
  def get_comm_event_log(client, unit_id, options \\ []) do
    request(client, unit_id, :get_comm_event_log, options)
  end

  @doc "複数の Coil を書き込みます。"
  @spec write_multiple_coils(
          term(),
          0..255,
          AVModbus.address(),
          [boolean()],
          [retry_option()]
        ) :: request_result()
  def write_multiple_coils(client, unit_id, address, values, options \\ []) do
    request(client, unit_id, {:write_multiple_coils, address, values}, options)
  end

  @doc "複数の Holding Register を書き込みます。"
  @spec write_multiple_registers(
          term(),
          0..255,
          AVModbus.address(),
          [AVModbus.word()],
          [retry_option()]
        ) :: request_result()
  def write_multiple_registers(client, unit_id, address, values, options \\ []) do
    request(client, unit_id, {:write_multiple_registers, address, values}, options)
  end

  @doc "server identification を読み取ります。"
  @spec report_server_id(term(), 0..255, [retry_option()]) :: request_result()
  def report_server_id(client, unit_id, options \\ []) do
    request(client, unit_id, :report_server_id, options)
  end

  @doc "mask を使って 1 個の Holding Register を変更します。"
  @spec mask_write_register(
          term(),
          0..255,
          AVModbus.address(),
          AVModbus.word(),
          AVModbus.word(),
          [retry_option()]
        ) :: request_result()
  def mask_write_register(
        client,
        unit_id,
        address,
        and_mask,
        or_mask,
        options \\ []
      ) do
    request(
      client,
      unit_id,
      {:mask_write_register, address, and_mask, or_mask},
      options
    )
  end

  @doc "複数の Holding Register の書き込みと読み取りを 1 transaction で実行します。"
  @spec read_write_multiple_registers(
          term(),
          0..255,
          AVModbus.address(),
          pos_integer(),
          AVModbus.address(),
          [AVModbus.word()],
          [retry_option()]
        ) :: request_result()
  def read_write_multiple_registers(
        client,
        unit_id,
        read_address,
        read_quantity,
        write_address,
        write_values,
        options \\ []
      ) do
    request(
      client,
      unit_id,
      {:read_write_multiple_registers, read_address, read_quantity, write_address, write_values},
      options
    )
  end

  @doc "FIFO queue を読み取ります。"
  @spec read_fifo_queue(term(), 0..255, AVModbus.address(), [retry_option()]) ::
          request_result()
  def read_fifo_queue(client, unit_id, address, options \\ []) do
    request(client, unit_id, {:read_fifo_queue, address}, options)
  end

  @doc "file record group を読み取ります。"
  @spec read_file_record(term(), 0..255, [term()], [retry_option()]) :: request_result()
  def read_file_record(client, unit_id, groups, options \\ []) do
    request(client, unit_id, {:read_file_record, groups}, options)
  end

  @doc "file record group を書き込みます。"
  @spec write_file_record(term(), 0..255, [term()], [retry_option()]) :: request_result()
  def write_file_record(client, unit_id, groups, options \\ []) do
    request(client, unit_id, {:write_file_record, groups}, options)
  end

  @doc "任意の MEI type で Encapsulated Interface Transport を実行します。"
  @spec encapsulated_interface_transport(
          term(),
          0..255,
          byte(),
          binary(),
          [retry_option()]
        ) :: request_result()
  def encapsulated_interface_transport(
        client,
        unit_id,
        mei_type,
        data,
        options \\ []
      ) do
    request(client, unit_id, {:encapsulated_interface_transport, mei_type, data}, options)
  end

  @doc "user-defined public Function Code の request を送ります。"
  @spec custom(term(), 0..255, 1..127, binary(), [retry_option()]) :: request_result()
  def custom(client, unit_id, function, data, options \\ []) do
    request(client, unit_id, {:custom, function, data}, options)
  end

  @doc """
  指定 category の device identification を全 page 読み、object map として返します。

  category は `:category` option で指定し、既定値は `:basic` です。request 共通の
  `:timeout`、`:retries`、`:backoff` も指定できます。
  """
  @spec read_device_identification(term(), 0..255, [device_identification_option()]) ::
          {:ok, map()} | {:error, term()}
  def read_device_identification(client, unit_id, options \\ [])

  def read_device_identification(client, unit_id, options) when is_list(options) do
    category = option(options, :category, :basic)

    if category in [:basic, :regular, :extended] do
      request_options = remove_option(options, :category, [])
      read_device_identification_page(client, unit_id, category, 0, request_options, %{}, 0)
    else
      {:error, :invalid_device_id_category}
    end
  end

  def read_device_identification(_client, _unit_id, _options), do: {:error, :invalid_options}

  @doc """
  request を送信し、result を待ちます。

  最後の引数は `timeout:`、`retries:`、`backoff:` の keyword options です。
  `retries:` は既定で `0` です。正の retry 回数は idempotent read
  にだけ許可し、`:timeout` と `:closed` の場合だけ再送します。
  """
  @spec request(term(), 0..255, PDU.request(), [retry_option()]) ::
          {:ok, term()} | :ok | {:error, term()}
  def request(client, unit_id, request, options \\ [])

  def request(client, unit_id, request, options) when is_list(options) do
    with {:ok, config} <- request_config(options) do
      if config.retries > 0 do
        retry_request(client, unit_id, request, options)
      else
        do_request(client, unit_id, request, config.timeout)
      end
    end
  end

  def request(_client, _unit_id, _request, _options), do: {:error, :invalid_options}

  defp do_request(server, unit_id, request, timeout_ms) when is_pid(server) or is_atom(server) do
    case client_type(server) do
      :tcp -> do_request({__MODULE__, server, :tcp}, unit_id, request, timeout_ms)
      :serial -> do_request({__MODULE__, server}, unit_id, request, timeout_ms)
      {:error, _reason} = error -> error
    end
  end

  defp do_request({__MODULE__, server, :tcp}, unit_id, request, timeout_ms)
       when (is_pid(server) or is_atom(server)) and is_integer(unit_id) and unit_id >= 0 and
              unit_id <= 255 and
              (timeout_ms == :default or (is_integer(timeout_ms) and timeout_ms >= 0)) do
    managed_call(server, {:request, unit_id, request, request_timing(timeout_ms)})
  end

  defp do_request({__MODULE__, _pid, :tcp}, unit_id, _request, _timeout_ms)
       when not is_integer(unit_id) or unit_id < 0 or unit_id > 255,
       do: {:error, :invalid_unit_id}

  defp do_request({__MODULE__, _pid, :tcp}, _unit_id, _request, _timeout_ms),
    do: {:error, :invalid_timeout}

  defp do_request({__MODULE__, server}, unit_id, request, timeout_ms)
       when (is_pid(server) or is_atom(server)) and is_integer(unit_id) and unit_id >= 0 and
              unit_id <= 247 and
              (timeout_ms == :default or (is_integer(timeout_ms) and timeout_ms >= 0)) do
    case validate_unit_request(unit_id, request) do
      :ok ->
        managed_call(server, {:request, unit_id, request, request_timing(timeout_ms)})

      error ->
        error
    end
  end

  defp do_request({__MODULE__, _pid}, unit_id, _request, _timeout_ms)
       when not is_integer(unit_id) or unit_id < 0 or unit_id > 247,
       do: {:error, :invalid_unit_id}

  defp do_request({__MODULE__, _pid}, _unit_id, _request, _timeout_ms),
    do: {:error, :invalid_timeout}

  defp do_request(uart, unit_id, request, :default) do
    transaction(UART, uart, unit_id, request, @default_timeout)
  end

  defp do_request(uart, unit_id, request, timeout_ms) do
    transaction(UART, uart, unit_id, request, timeout_ms)
  end

  @doc """
  transient failure の場合だけ idempotent read request を再試行します。

  `:timeout` は各 attempt の timeout、`:retries` は最初の attempt 後に許可する追加回数、
  `:backoff` は attempt 間の `{first, maximum}` delay です。timeout の省略時は managed client の
  startup default（既定 `#{@default_timeout}` ms）、unmanaged UART では `#{@default_timeout}` ms を
  使います。retry と backoff の既定値は `1` 回、`{100, 1000}` ms です。

  `:timeout` と `:closed` だけを retry します。write、diagnostics、custom request、
  Modbus exception、invalid response は replay しません。
  """
  @spec retry_request(term(), 0..255, PDU.request(), [retry_option()]) ::
          {:ok, term()} | {:error, term()}
  def retry_request(client, unit_id, request, options \\ [])

  def retry_request(client, unit_id, request, options) when is_list(options) do
    with :ok <- validate_retry_request(request),
         {:ok, config} <- retry_config(options) do
      {first_backoff, maximum_backoff} = config.backoff

      do_retry_request(
        client,
        unit_id,
        request,
        config.timeout,
        config.retries,
        first_backoff,
        maximum_backoff
      )
    end
  end

  def retry_request(_client, _unit_id, _request, _options), do: {:error, :invalid_options}

  @doc """
  transaction の完了を待たず managed client に request を送ります。

  request を受け付けた場合は reference を返し、recipient は後で
  `{AVModbus.Client, reference, result}` を 1 回受信します。受付時点で client を利用できない場合や
  queue が満杯の場合は reference を作らず `{:error, reason}` を返します。
  `request/4` と同様に、受付までの時間と queue 待ち時間も timeout に含まれます。

  第 4 引数には `timeout:` と `to:` の keyword options を指定できます。
  """
  @spec send_request(
          t() | server(),
          0..255,
          PDU.request(),
          [async_option()]
        ) ::
          reference() | {:error, term()}
  def send_request(client, unit_id, request, options \\ [])

  def send_request(client, unit_id, request, options) when is_list(options) do
    recipient = option(options, :to, self())

    with :ok <- validate_async_options(options),
         {:ok, timeout_ms} <- request_timeout_option(options),
         :ok <- validate_recipient(recipient) do
      do_send_request(client, unit_id, request, timeout_ms, recipient)
    end
  end

  def send_request(_client, _unit_id, _request, _options), do: {:error, :invalid_options}

  defp do_send_request(server, unit_id, request, timeout_ms, recipient)
       when is_pid(server) or is_atom(server) do
    case client_type(server) do
      :tcp -> do_send_request({__MODULE__, server, :tcp}, unit_id, request, timeout_ms, recipient)
      :serial -> do_send_request({__MODULE__, server}, unit_id, request, timeout_ms, recipient)
      {:error, _reason} = error -> error
    end
  end

  defp do_send_request({__MODULE__, server, :tcp}, unit_id, request, timeout_ms, recipient)
       when (is_pid(server) or is_atom(server)) and is_integer(unit_id) and unit_id >= 0 and
              unit_id <= 255 and
              (timeout_ms == :default or (is_integer(timeout_ms) and timeout_ms >= 0)) and
              is_pid(recipient) do
    reference = make_ref()

    case managed_call(
           server,
           {:send_request, unit_id, request, request_timing(timeout_ms), recipient, reference}
         ) do
      :ok -> reference
      {:error, _reason} = error -> error
    end
  end

  defp do_send_request(
         {__MODULE__, _pid, :tcp},
         unit_id,
         _request,
         _timeout_ms,
         _recipient
       )
       when not is_integer(unit_id) or unit_id < 0 or unit_id > 255,
       do: {:error, :invalid_unit_id}

  defp do_send_request({__MODULE__, _pid, :tcp}, _unit_id, _request, timeout_ms, _recipient)
       when not is_integer(timeout_ms) or timeout_ms < 0,
       do: {:error, :invalid_timeout}

  defp do_send_request({__MODULE__, _pid, :tcp}, _unit_id, _request, _timeout_ms, _recipient),
    do: {:error, :invalid_recipient}

  defp do_send_request({__MODULE__, server}, unit_id, request, timeout_ms, recipient)
       when (is_pid(server) or is_atom(server)) and is_integer(unit_id) and unit_id >= 0 and
              unit_id <= 247 and
              (timeout_ms == :default or (is_integer(timeout_ms) and timeout_ms >= 0)) and
              is_pid(recipient) do
    case validate_unit_request(unit_id, request) do
      :ok ->
        reference = make_ref()
        timing = request_timing(timeout_ms)

        case managed_call(
               server,
               {:send_request, unit_id, request, timing, recipient, reference}
             ) do
          :ok -> reference
          {:error, _reason} = error -> error
        end

      error ->
        error
    end
  end

  defp do_send_request({__MODULE__, _pid}, unit_id, _request, _timeout_ms, _recipient)
       when not is_integer(unit_id) or unit_id < 0 or unit_id > 247,
       do: {:error, :invalid_unit_id}

  defp do_send_request({__MODULE__, _pid}, _unit_id, _request, timeout_ms, _recipient)
       when not is_integer(timeout_ms) or timeout_ms < 0,
       do: {:error, :invalid_timeout}

  defp do_send_request({__MODULE__, _pid}, _unit_id, _request, _timeout_ms, _recipient),
    do: {:error, :invalid_recipient}

  defp do_send_request(_client, _unit_id, _request, _timeout_ms, _recipient),
    do: {:error, :invalid_client}

  defp request_timing(:default), do: {:default, monotonic_ms()}

  defp request_timing(timeout_ms),
    do: {:deadline, monotonic_ms() + timeout_ms, timeout_ms == 0}

  @doc false
  def resolve_request_timing({:default, submitted_ms}, timeout_ms),
    do: {submitted_ms + timeout_ms, false}

  def resolve_request_timing({:deadline, deadline_ms, allow_expired}, _timeout_ms),
    do: {deadline_ms, allow_expired}

  defp deadline_recipient(recipient, _reference, _deadline_ms, true), do: recipient

  defp deadline_recipient(recipient, reference, deadline_ms, false) do
    spawn(fn -> await_deadline_result(recipient, reference, deadline_ms) end)
  end

  defp await_deadline_result(recipient, reference, deadline_ms) do
    timeout_ms = max(deadline_ms - monotonic_ms(), 0)

    receive do
      {__MODULE__, ^reference, result} ->
        send(recipient, {__MODULE__, reference, result})
    after
      timeout_ms ->
        send(recipient, {__MODULE__, reference, {:error, :timeout}})
    end
  end

  @impl true
  def init({:open, transport, config}) do
    state = new_state(transport, nil, true, true, config)
    {:ok, open_transport(state)}
  end

  def init({:ready, transport, uart, close_on_stop, config}) do
    {:ok, new_state(transport, uart, close_on_stop, close_on_stop, config)}
  end

  @impl true
  def handle_call(:client_type, _from, state), do: {:reply, :serial, state}
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(
        {:request, unit_id, request, timing},
        from,
        state
      ) do
    {deadline_ms, allow_expired} = resolve_request_timing(timing, state.config.timeout)
    entry = serial_entry(unit_id, request, deadline_ms, allow_expired, {:call, from})
    {:noreply, submit_serial(state, entry)}
  end

  def handle_call(
        {:send_request, unit_id, request, timing, recipient, reference},
        _from,
        state
      ) do
    {deadline_ms, allow_expired} = resolve_request_timing(timing, state.config.timeout)

    case serial_capacity(state) do
      {:ok, capacity} ->
        result_recipient = deadline_recipient(recipient, reference, deadline_ms, allow_expired)

        entry =
          serial_entry(
            unit_id,
            request,
            deadline_ms,
            allow_expired,
            {:send, result_recipient, reference}
          )

        {:reply, :ok, commit_serial(state, entry, capacity)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :unsupported_call}, state}

  @impl true
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(:reopen, %{status: {:disconnected, _reason}, reopen: true} = state),
    do: {:noreply, open_transport(state)}

  def handle_info(
        {:serial_result, worker, result},
        %{active: %{worker: worker} = entry} = state
      ) do
    Process.demonitor(entry.monitor)
    next = %{state | active: nil}

    case result do
      {:transport_error, reason} ->
        serial_reply(entry, {:error, :closed})
        {:noreply, next |> fail_serial_queue({:error, :closed}) |> drop_transport(reason)}

      result ->
        serial_reply(entry, result)
        {:noreply, start_next_serial(next)}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, reason},
        %{active: %{worker: worker, monitor: monitor} = entry} = state
      ) do
    serial_reply(entry, {:error, :closed})

    next =
      state
      |> Map.put(:active, nil)
      |> fail_serial_queue({:error, :closed})
      |> drop_transport({:transaction_worker_down, reason})

    {:noreply, next}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.active do
      serial_reply(state.active, {:error, :closed})
      Process.exit(state.active.worker, :kill)
    end

    _state = fail_serial_queue(state, {:error, :closed})

    if state.close_on_stop and not is_nil(state.uart) do
      _result = state.transport.close(state.uart)
    end

    :ok
  end

  @doc false
  def transaction(transport, uart, unit_id, request, timeout_ms)
      when is_atom(transport) do
    transaction(transport, uart, unit_id, request, timeout_ms, [])
  end

  @doc false
  def transaction(transport, uart, unit_id, request, timeout_ms, options)
      when is_atom(transport) and is_integer(unit_id) and unit_id >= 0 and unit_id <= 247 and
             is_integer(timeout_ms) and timeout_ms >= 0 and is_list(options) do
    deadline_ms = monotonic_ms() + timeout_ms

    with {:ok, config} <- client_config(options) do
      case transaction_until(
             transport,
             uart,
             unit_id,
             request,
             deadline_ms,
             config,
             timeout_ms == 0
           ) do
        {:transport_error, reason} -> {:error, reason}
        result -> result
      end
    end
  end

  def transaction(_transport, _uart, unit_id, _request, _timeout_ms, _options)
      when not is_integer(unit_id) or unit_id < 0 or unit_id > 247,
      do: {:error, :invalid_unit_id}

  def transaction(_transport, _uart, _unit_id, _request, _timeout_ms, _options),
    do: {:error, :invalid_timeout}

  defp start_server(init_arg, name) do
    case gen_server_start(__MODULE__, init_arg, name) do
      {:ok, pid} -> {:ok, {__MODULE__, pid}}
      {:error, _reason} = error -> error
    end
  end

  defp start_tcp_server(host, options, name) do
    with {:ok, config} <- tcp_client_config(host, options),
         {:ok, pid} <- gen_server_start(AVModbus.Client.TCP, config, name) do
      {:ok, {__MODULE__, pid, :tcp}}
    end
  end

  defp gen_server_start(module, init_arg, nil),
    do: :gen_server.start_link(module, init_arg, [])

  defp gen_server_start(module, init_arg, name),
    do: :gen_server.start_link({:local, name}, module, init_arg, [])

  defp new_state(transport, uart, close_on_stop, reopen, config) do
    {backoff_min, backoff_max} = config.backoff

    %{
      transport: transport,
      uart: uart,
      close_on_stop: close_on_stop,
      reopen: reopen,
      config: config,
      status: if(is_nil(uart), do: :connecting, else: :connected),
      active: nil,
      queue: {[], []},
      backoff_min: backoff_min,
      backoff_max: backoff_max,
      reopen_delay: backoff_min
    }
  end

  defp serial_entry(unit_id, request, deadline_ms, allow_expired, reply) do
    %{
      unit_id: unit_id,
      request: request,
      deadline_ms: deadline_ms,
      allow_expired: allow_expired,
      reply: reply
    }
  end

  defp submit_serial(state, entry) do
    case serial_capacity(state) do
      {:ok, capacity} ->
        commit_serial(state, entry, capacity)

      {:error, _reason} = error ->
        serial_reply(entry, error)
        state
    end
  end

  defp serial_capacity(%{status: status}) when status != :connected, do: {:error, :closed}
  defp serial_capacity(%{active: nil}), do: {:ok, :active}

  defp serial_capacity(state) do
    if serial_queue_full?(state), do: {:error, :queue_full}, else: {:ok, :queue}
  end

  defp commit_serial(state, entry, :active), do: start_serial(state, entry)

  defp commit_serial(state, entry, :queue),
    do: %{state | queue: serial_queue_in(state.queue, entry)}

  defp start_serial(state, entry) do
    parent = self()

    worker =
      spawn(fn ->
        result =
          if entry.deadline_ms >= monotonic_ms() or entry.allow_expired do
            transaction_until(
              state.transport,
              state.uart,
              entry.unit_id,
              entry.request,
              entry.deadline_ms,
              state.config,
              entry.allow_expired
            )
          else
            {:error, :timeout}
          end

        send(parent, {:serial_result, self(), result})
      end)

    monitor = Process.monitor(worker)
    %{state | active: Map.merge(entry, %{worker: worker, monitor: monitor})}
  end

  defp start_next_serial(%{status: :connected} = state) do
    case serial_queue_out(state.queue) do
      {{:value, entry}, rest} -> start_serial(%{state | queue: rest}, entry)
      :empty -> state
    end
  end

  defp start_next_serial(state), do: state

  defp serial_reply(%{reply: {:call, from}}, result), do: :gen_server.reply(from, result)

  defp serial_reply(%{reply: {:send, recipient, reference}}, result),
    do: send(recipient, {__MODULE__, reference, result})

  defp fail_serial_queue(state, result) do
    state.queue
    |> serial_queue_to_list()
    |> serial_reply_all(result)

    %{state | queue: {[], []}}
  end

  defp serial_reply_all([], _result), do: :ok

  defp serial_reply_all([entry | rest], result) do
    serial_reply(entry, result)
    serial_reply_all(rest, result)
  end

  defp serial_queue_full?(%{config: %{max_queue: :infinity}}), do: false

  defp serial_queue_full?(state) do
    {front, back} = state.queue
    serial_list_length(front) + serial_list_length(back) >= state.config.max_queue
  end

  defp serial_queue_in({front, back}, entry), do: {front, [entry | back]}

  defp serial_queue_out({[entry | rest], back}), do: {{:value, entry}, {rest, back}}
  defp serial_queue_out({[], []}), do: :empty
  defp serial_queue_out({[], back}), do: serial_queue_out({serial_reverse(back, []), []})

  defp serial_queue_to_list({front, back}), do: serial_append(front, serial_reverse(back, []))
  defp serial_append([], tail), do: tail
  defp serial_append([value | rest], tail), do: [value | serial_append(rest, tail)]

  defp serial_list_length(values), do: serial_list_length(values, 0)
  defp serial_list_length([], result), do: result
  defp serial_list_length([_value | rest], result), do: serial_list_length(rest, result + 1)

  defp serial_reverse([], result), do: result
  defp serial_reverse([value | rest], result), do: serial_reverse(rest, [value | result])

  defp open_transport(state) do
    case Serial.open_transport(state.transport, state.config.serial) do
      {:ok, uart} ->
        %{state | uart: uart, status: :connected, reopen_delay: state.backoff_min}

      {:error, reason} ->
        schedule_reopen(state, reason)

      other ->
        schedule_reopen(state, {:transport_open, other})
    end
  end

  defp drop_transport(state, reason) do
    if state.close_on_stop and state.uart, do: state.transport.close(state.uart)

    state = %{state | uart: nil}

    if state.reopen do
      schedule_reopen(state, reason)
    else
      %{state | status: {:disconnected, reason}}
    end
  end

  defp schedule_reopen(state, reason) do
    Process.send_after(self(), :reopen, state.reopen_delay)

    %{
      state
      | status: {:disconnected, reason},
        reopen_delay: min(state.reopen_delay * 2, state.backoff_max)
    }
  end

  defp transaction_until(
         transport,
         uart,
         unit_id,
         request,
         deadline_ms,
         config,
         allow_expired
       ) do
    with :ok <- validate_unit_request(unit_id, request),
         {:ok, pdu} <- PDU.encode_request(request),
         :ok <- wait_to_transmit(unit_id, deadline_ms, config, allow_expired),
         {:ok, frame} <- encode_frame(config.mode, unit_id, pdu) do
      case transport.write(uart, frame) do
        :ok -> complete_transaction(transport, uart, unit_id, request, frame, deadline_ms, config)
        {:error, reason} -> {:transport_error, reason}
        other -> {:transport_error, {:transport_write, other}}
      end
    end
  end

  defp complete_transaction(transport, uart, 0, _request, frame, _deadline_ms, config) do
    echo = config.echo
    turnaround_ms = config.turnaround
    turnaround_deadline_ms = monotonic_ms() + turnaround_ms

    if echo do
      drain_broadcast_echo(transport, uart, frame, turnaround_deadline_ms)
    else
      Process.sleep(turnaround_ms)
      :ok
    end
  end

  defp complete_transaction(transport, uart, unit_id, request, frame, deadline_ms, config) do
    expected_echo = if config.echo, do: frame, else: <<>>

    receive_response(
      config.mode,
      transport,
      uart,
      unit_id,
      request,
      deadline_ms,
      expected_echo,
      config.silence
    )
  end

  defp validate_unit_request(0, request) do
    if PDU.broadcast_request?(request), do: :ok, else: {:error, :invalid_broadcast_request}
  end

  defp validate_unit_request(_unit_id, _request), do: :ok

  defp wait_to_transmit(unit_id, _deadline_ms, %{gap: 0}, true) when unit_id != 0, do: :ok

  defp wait_to_transmit(unit_id, deadline_ms, config, _allow_expired) do
    after_write_ms = if unit_id == 0, do: config.turnaround, else: 0

    if deadline_ms - monotonic_ms() >= config.gap + after_write_ms do
      if config.gap > 0, do: Process.sleep(config.gap)

      if deadline_ms - monotonic_ms() >= after_write_ms,
        do: :ok,
        else: {:error, :timeout}
    else
      {:error, :timeout}
    end
  end

  defp drain_broadcast_echo(transport, uart, expected_echo, deadline_ms) do
    remaining_ms = deadline_ms - monotonic_ms()

    if remaining_ms <= 0 do
      :ok
    else
      case transport.read(uart, remaining_ms) do
        {:ok, data} when is_binary(data) and data != <<>> ->
          {remaining_echo, _unexpected_data} = Serial.strip_echo(expected_echo, data)

          if remaining_echo == <<>> do
            sleep_until(deadline_ms)
            :ok
          else
            drain_broadcast_echo(transport, uart, remaining_echo, deadline_ms)
          end

        {:ok, <<>>} ->
          sleep_until(deadline_ms)
          :ok

        {:error, :timeout} ->
          sleep_until(deadline_ms)
          :ok

        {:error, reason} ->
          {:transport_error, reason}

        other ->
          {:transport_error, {:transport_read, other}}
      end
    end
  end

  defp sleep_until(deadline_ms) do
    remaining_ms = deadline_ms - monotonic_ms()
    if remaining_ms > 0, do: Process.sleep(remaining_ms)
  end

  defp receive_response(
         :rtu,
         transport,
         uart,
         unit_id,
         request,
         deadline_ms,
         expected_echo,
         silence_ms
       ) do
    with {:ok, response} <-
           read_response(
             transport,
             uart,
             unit_id,
             request,
             deadline_ms,
             expected_echo,
             silence_ms,
             <<>>,
             false
           ),
         {:ok, ^unit_id, response_pdu} <- RTU.decode(response) do
      PDU.decode_response(request, response_pdu)
    end
  end

  defp receive_response(
         :ascii,
         transport,
         uart,
         unit_id,
         request,
         deadline_ms,
         expected_echo,
         _silence_ms
       ) do
    read_ascii_response(
      transport,
      uart,
      unit_id,
      request,
      deadline_ms,
      expected_echo,
      <<>>,
      false
    )
  end

  defp read_ascii_response(
         transport,
         uart,
         unit_id,
         request,
         deadline_ms,
         expected_echo,
         buffer,
         has_read
       ) do
    case ASCII.split(buffer) do
      {:ok, frame, rest} ->
        case ASCII.decode(frame) do
          {:ok, ^unit_id, response_pdu} ->
            PDU.decode_response(request, response_pdu)

          _invalid_or_other_unit ->
            read_ascii_response(
              transport,
              uart,
              unit_id,
              request,
              deadline_ms,
              expected_echo,
              rest,
              has_read
            )
        end

      {:skip, rest} ->
        read_ascii_response(
          transport,
          uart,
          unit_id,
          request,
          deadline_ms,
          expected_echo,
          rest,
          has_read
        )

      :more ->
        with {:ok, remaining_ms} <- remaining_timeout(deadline_ms, has_read) do
          case transport.read(uart, remaining_ms) do
            {:ok, data} when is_binary(data) and data != <<>> ->
              {remaining_echo, response_data} = Serial.strip_echo(expected_echo, data)

              read_ascii_response(
                transport,
                uart,
                unit_id,
                request,
                deadline_ms,
                remaining_echo,
                <<buffer::binary, response_data::binary>>,
                true
              )

            {:ok, <<>>} ->
              {:error, :timeout}

            {:error, :timeout} ->
              {:error, :timeout}

            {:error, reason} ->
              {:transport_error, reason}

            other ->
              {:transport_error, {:transport_read, other}}
          end
        end
    end
  end

  defp read_response(
         transport,
         uart,
         unit_id,
         request,
         deadline_ms,
         expected_echo,
         silence_ms,
         buffer,
         has_read
       ) do
    case RTU.split_response(buffer, unit_id, request) do
      {:ok, frame, _rest} ->
        {:ok, frame}

      :skip ->
        <<_byte, rest::binary>> = buffer

        read_response(
          transport,
          uart,
          unit_id,
          request,
          deadline_ms,
          expected_echo,
          silence_ms,
          rest,
          has_read
        )

      :more ->
        with {:ok, remaining_ms} <- remaining_timeout(deadline_ms, has_read) do
          case transport.read(uart, remaining_ms) do
            {:ok, data} when is_binary(data) and data != <<>> ->
              {remaining_echo, response_data} = Serial.strip_echo(expected_echo, data)

              with {:ok, next_buffer} <- append_rtu_response(buffer, response_data) do
                read_response(
                  transport,
                  uart,
                  unit_id,
                  request,
                  deadline_ms,
                  remaining_echo,
                  silence_ms,
                  next_buffer,
                  true
                )
              end

            {:ok, <<>>} ->
              {:error, :timeout}

            {:error, :timeout} ->
              {:error, :timeout}

            {:error, reason} ->
              {:transport_error, reason}

            other ->
              {:transport_error, {:transport_read, other}}
          end
        end

      :unknown ->
        with {:ok, remaining_ms} <- remaining_timeout(deadline_ms, has_read) do
          quiet_wait_ms = min(remaining_ms, silence_ms)

          case transport.read(uart, quiet_wait_ms) do
            {:ok, data} when is_binary(data) and data != <<>> ->
              {remaining_echo, response_data} = Serial.strip_echo(expected_echo, data)

              with {:ok, next_buffer} <- append_rtu_response(buffer, response_data) do
                read_response(
                  transport,
                  uart,
                  unit_id,
                  request,
                  deadline_ms,
                  remaining_echo,
                  silence_ms,
                  next_buffer,
                  true
                )
              end

            {:ok, <<>>} ->
              RTU.complete_silence_response(buffer, unit_id, request)

            {:error, :timeout} ->
              RTU.complete_silence_response(buffer, unit_id, request)

            {:error, reason} ->
              {:transport_error, reason}

            other ->
              {:transport_error, {:transport_read, other}}
          end
        end

      :overflow ->
        {:error, :frame_too_long}
    end
  end

  defp append_rtu_response(buffer, data)
       when byte_size(buffer) + byte_size(data) <= @max_rtu_frame_size,
       do: {:ok, <<buffer::binary, data::binary>>}

  defp append_rtu_response(_buffer, _data), do: {:error, :frame_too_long}

  defp remaining_timeout(deadline_ms, has_read) do
    remaining_ms = deadline_ms - monotonic_ms()

    cond do
      remaining_ms >= 0 -> {:ok, remaining_ms}
      not has_read -> {:ok, 0}
      true -> {:error, :timeout}
    end
  end

  defp client_config(options) do
    with :ok <- validate_options(options),
         mode = option(options, :transport, :rtu),
         :ok <- validate_serial_transport(mode),
         serial = option(options, :serial, []),
         {:ok, defaults} <- Serial.Config.defaults(mode, serial),
         echo = option(options, :echo, @default_echo),
         turnaround = option(options, :turnaround, @default_turnaround),
         silence = option(options, :silence, defaults.silence),
         gap = option(options, :gap, defaults.gap),
         max_queue = option(options, :max_queue, @default_max_queue),
         timeout = option(options, :timeout, @default_timeout),
         backoff = option(options, :backoff, @default_backoff),
         :ok <- validate_echo(echo),
         :ok <- validate_turnaround(turnaround),
         :ok <- validate_silence(silence),
         :ok <- validate_gap(gap),
         :ok <- validate_max_queue(max_queue),
         :ok <- validate_default_timeout(timeout),
         :ok <- validate_backoff(backoff) do
      {:ok,
       %{
         mode: mode,
         serial: serial,
         echo: echo,
         turnaround: turnaround,
         silence: silence,
         gap: gap,
         max_queue: max_queue,
         timeout: timeout,
         backoff: backoff
       }}
    end
  end

  defp tcp_client_config(host, options) do
    with :ok <- validate_tcp_options(options),
         port = option(options, :port, 502),
         max_pending = option(options, :max_pending, 4),
         max_queue = option(options, :max_queue, @default_max_queue),
         check_unit = option(options, :check_unit, true),
         connect_timeout = option(options, :connect_timeout, 5_000),
         timeout = option(options, :timeout, @default_timeout),
         backoff = option(options, :backoff, @default_backoff),
         :ok <- validate_tcp_host(host),
         :ok <- validate_tcp_port(port),
         :ok <- validate_max_pending(max_pending),
         :ok <- validate_max_queue(max_queue),
         :ok <- validate_check_unit(check_unit),
         :ok <- validate_connect_timeout(connect_timeout),
         :ok <- validate_default_timeout(timeout),
         :ok <- validate_backoff(backoff) do
      {:ok,
       %{
         host: normalize_tcp_host(host),
         port: port,
         max_pending: max_pending,
         max_queue: max_queue,
         check_unit: check_unit,
         connect_timeout: connect_timeout,
         timeout: timeout,
         backoff: backoff
       }}
    end
  end

  defp validate_tcp_options([]), do: :ok

  defp validate_tcp_options([{key, _value} | rest])
       when key in [
              :transport,
              :host,
              :port,
              :max_pending,
              :max_queue,
              :check_unit,
              :connect_timeout,
              :timeout,
              :backoff,
              :name
            ],
       do: validate_tcp_options(rest)

  defp validate_tcp_options([option | _rest]), do: {:error, {:invalid_option, option}}

  defp validate_tcp_host(host) when is_binary(host) or is_list(host), do: :ok

  defp validate_tcp_host(host) when is_tuple(host) and tuple_size(host) in [4, 8], do: :ok

  defp validate_tcp_host(_host), do: {:error, :invalid_tcp_host}

  defp validate_tcp_port(port) when is_integer(port) and port >= 1 and port <= 65_535, do: :ok
  defp validate_tcp_port(_port), do: {:error, :invalid_port_option}

  defp validate_max_pending(value)
       when is_integer(value) and value >= 1 and value <= 65_536,
       do: :ok

  defp validate_max_pending(_value), do: {:error, :invalid_max_pending_option}

  defp validate_max_queue(:infinity), do: :ok

  defp validate_max_queue(value)
       when is_integer(value) and value >= 0 and value <= 65_536,
       do: :ok

  defp validate_max_queue(_value), do: {:error, :invalid_max_queue_option}

  defp validate_check_unit(value) when is_boolean(value), do: :ok
  defp validate_check_unit(_value), do: {:error, :invalid_check_unit_option}

  defp validate_connect_timeout(value) when is_integer(value) and value > 0, do: :ok
  defp validate_connect_timeout(_value), do: {:error, :invalid_connect_timeout_option}

  defp validate_default_timeout(value) when is_integer(value) and value > 0, do: :ok
  defp validate_default_timeout(_value), do: {:error, :invalid_timeout_option}

  defp normalize_tcp_host(host) when is_binary(host),
    do: normalize_tcp_host(:erlang.binary_to_list(host))

  defp normalize_tcp_host(host) when is_list(host) do
    case :inet.parse_address(host) do
      {:ok, address} -> address
      {:error, _reason} -> host
    end
  catch
    _kind, _reason -> host
  end

  defp normalize_tcp_host(host), do: host

  defp client_name(options) do
    case option(options, :name, nil) do
      nil -> {:ok, nil}
      name when is_atom(name) -> {:ok, name}
      _name -> {:error, :invalid_name_option}
    end
  end

  defp required_transport(options) do
    case find_option(options, :transport) do
      {:ok, transport} when transport in [:rtu, :ascii, :tcp] -> {:ok, transport}
      {:ok, _transport} -> {:error, :invalid_transport_option}
      :error -> {:error, :missing_transport_option}
    end
  end

  defp required_host(options) do
    case find_option(options, :host) do
      {:ok, host} -> {:ok, host}
      :error -> {:error, :missing_host_option}
    end
  end

  defp managed_client_config(options) do
    with {:ok, transport} <- required_transport(options),
         :ok <- require_serial_transport(transport) do
      client_config(options)
    end
  end

  defp require_serial_transport(transport) when transport in [:rtu, :ascii], do: :ok
  defp require_serial_transport(_transport), do: {:error, :invalid_transport_option}

  defp reject_tls([]), do: :ok

  defp reject_tls([{key, _value} | _rest]) when key in [:tls, :ssl],
    do: {:error, :tls_not_supported}

  defp reject_tls([_option | rest]), do: reject_tls(rest)

  defp client_type(server) do
    case managed_call(server, :client_type) do
      type when type in [:serial, :tcp] -> type
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_client}
    end
  end

  defp do_retry_request(
         client,
         unit_id,
         request,
         timeout_ms,
         retries,
         backoff_ms,
         maximum_backoff_ms
       ) do
    case do_request(client, unit_id, request, timeout_ms) do
      {:error, reason} when reason in [:timeout, :closed] and retries > 0 ->
        Process.sleep(backoff_ms)

        do_retry_request(
          client,
          unit_id,
          request,
          timeout_ms,
          retries - 1,
          min(backoff_ms * 2, maximum_backoff_ms),
          maximum_backoff_ms
        )

      result ->
        result
    end
  end

  defp retry_config(options) do
    retry_config(options, 1)
  end

  defp request_config(options) do
    retry_config(options, 0)
  end

  defp retry_config(options, default_retries) do
    retries = option(options, :retries, default_retries)
    backoff = option(options, :backoff, {100, 1_000})

    with :ok <- validate_retry_options(options),
         {:ok, timeout} <- request_timeout_option(options),
         :ok <- validate_retries(retries),
         :ok <- validate_backoff(backoff) do
      {:ok, %{timeout: timeout, retries: retries, backoff: backoff}}
    end
  end

  defp validate_retry_options([]), do: :ok

  defp validate_retry_options([{key, _value} | rest])
       when key in [:timeout, :retries, :backoff],
       do: validate_retry_options(rest)

  defp validate_retry_options([option | _rest]), do: {:error, {:invalid_option, option}}

  defp validate_async_options([]), do: :ok

  defp validate_async_options([{key, _value} | rest]) when key in [:timeout, :to],
    do: validate_async_options(rest)

  defp validate_async_options([option | _rest]), do: {:error, {:invalid_option, option}}

  defp validate_retry_timeout(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_retry_timeout(_value), do: {:error, :invalid_timeout_option}

  defp request_timeout_option(options) do
    case find_option(options, :timeout) do
      :error ->
        {:ok, :default}

      {:ok, timeout} ->
        case validate_retry_timeout(timeout) do
          :ok -> {:ok, timeout}
          {:error, _reason} = error -> error
        end
    end
  end

  defp validate_retries(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_retries(_value), do: {:error, :invalid_retries_option}

  defp validate_recipient(value) when is_pid(value), do: :ok
  defp validate_recipient(_value), do: {:error, :invalid_recipient}

  defp validate_retry_request(request) do
    if idempotent_read?(request), do: :ok, else: {:error, :retry_requires_idempotent_read}
  end

  defp idempotent_read?(request)
       when request in [
              :read_exception_status,
              :get_comm_event_counter,
              :get_comm_event_log,
              :report_server_id
            ],
       do: true

  defp idempotent_read?({kind, _address, _quantity})
       when kind in [
              :read_coils,
              :read_discrete_inputs,
              :read_holding_registers,
              :read_input_registers
            ],
       do: true

  defp idempotent_read?({kind, _argument})
       when kind in [:read_file_record, :read_fifo_queue],
       do: true

  defp idempotent_read?({:read_device_identification, _category, _object_id}), do: true
  defp idempotent_read?(_request), do: false

  defp managed_call(server, message) do
    try do
      :gen_server.call(server, message, :infinity)
    catch
      :exit, _reason -> {:error, :closed}
    end
  end

  defp validate_options([]), do: :ok

  defp validate_options([{key, _value} | rest])
       when key in [
              :transport,
              :echo,
              :turnaround,
              :silence,
              :gap,
              :serial,
              :max_queue,
              :timeout,
              :backoff,
              :name
            ],
       do: validate_options(rest)

  defp validate_options([option | _rest]), do: {:error, {:invalid_option, option}}

  defp option([], _key, default), do: default
  defp option([{key, value} | _rest], key, _default), do: value
  defp option([_option | rest], key, default), do: option(rest, key, default)

  defp remove_option([], _key, reversed), do: :lists.reverse(reversed)

  defp remove_option([{key, _value} | rest], key, reversed),
    do: remove_option(rest, key, reversed)

  defp remove_option([option | rest], key, reversed),
    do: remove_option(rest, key, [option | reversed])

  defp find_option([], _key), do: :error
  defp find_option([{key, value} | _rest], key), do: {:ok, value}
  defp find_option([_option | rest], key), do: find_option(rest, key)

  defp validate_echo(value) when is_boolean(value), do: :ok
  defp validate_echo(_value), do: {:error, :invalid_echo_option}

  defp validate_turnaround(value) when is_integer(value) and value > 0, do: :ok
  defp validate_turnaround(_value), do: {:error, :invalid_turnaround_option}

  defp validate_silence(value) when is_integer(value) and value > 0, do: :ok
  defp validate_silence(_value), do: {:error, :invalid_silence_option}

  defp validate_gap(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_gap(_value), do: {:error, :invalid_gap_option}

  defp validate_backoff({minimum, maximum})
       when is_integer(minimum) and minimum > 0 and is_integer(maximum) and maximum >= minimum,
       do: :ok

  defp validate_backoff(_value), do: {:error, :invalid_backoff_option}

  defp validate_serial_transport(value) when value in [:rtu, :ascii], do: :ok
  defp validate_serial_transport(_value), do: {:error, :invalid_transport_option}

  defp encode_frame(:rtu, unit_id, pdu), do: RTU.encode(unit_id, pdu)
  defp encode_frame(:ascii, unit_id, pdu), do: ASCII.encode(unit_id, pdu)

  defp read_device_identification_page(
         _client,
         _unit_id,
         _category,
         _object_id,
         _options,
         _objects,
         256
       ),
       do: {:error, :malformed_response}

  defp read_device_identification_page(
         client,
         unit_id,
         category,
         object_id,
         options,
         objects,
         requests
       ) do
    case request(
           client,
           unit_id,
           {:read_device_identification, category, object_id},
           options
         ) do
      {:ok, answer} ->
        merged = put_device_id_objects(answer.objects, objects)

        if answer.more_follows and answer.next_object_id > object_id do
          read_device_identification_page(
            client,
            unit_id,
            category,
            answer.next_object_id,
            options,
            merged,
            requests + 1
          )
        else
          {:ok, merged}
        end

      error ->
        error
    end
  end

  defp put_device_id_objects([], objects), do: objects

  defp put_device_id_objects([{object_id, value} | rest], objects) do
    put_device_id_objects(rest, Map.put(objects, object_id, value))
  end

  defp monotonic_ms, do: :erlang.monotonic_time(:millisecond)
end
