defmodule AVModbus.Memory do
  @moduledoc """
  Modbus data model の sparse in-memory implementation です。

  coils、discrete inputs、holding registers、input registers、file records、FIFO を
  `AVModbus.Server` handler API から利用できます。未設定の bit は `false`、register は `0` として読み、
  明示的に書き込まれた値だけを memory に保持します。
  """

  import Bitwise

  @behaviour :gen_server
  @behaviour AVModbus.Server

  @tables [:coil, :discrete_input, :holding_register, :input_register]

  @type table :: :coil | :discrete_input | :holding_register | :input_register
  @type server :: pid() | atom()

  @doc false
  def child_spec(options) do
    %{
      id: option(options, :name, __MODULE__),
      start: {__MODULE__, :start_link, [options]}
    }
  end

  @doc "caller に link した sparse Modbus data model を起動します。"
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(options \\ [])

  def start_link(options) when is_list(options) do
    with :ok <- validate_options(options),
         {:ok, sizes} <- table_sizes(options),
         {:ok, files} <- validate_size(option(options, :files, 10), 100, :files),
         {:ok, name} <- validate_name(option(options, :name, nil)) do
      state = %{sizes: sizes, files: files, data: %{}}

      case name do
        nil -> :gen_server.start_link(__MODULE__, state, [])
        registered -> :gen_server.start_link({:local, registered}, __MODULE__, state, [])
      end
    end
  end

  def start_link(_options), do: {:error, :invalid_options}

  @doc "data-model table から `count` 個の値を返します。"
  @spec get(server(), table(), non_neg_integer(), pos_integer()) ::
          [boolean() | non_neg_integer()] | {:error, term()}
  def get(memory, table, address, count \\ 1)

  def get(memory, table, address, count) when table in @tables,
    do: :gen_server.call(memory, {:get, table, address, count})

  def get(_memory, _table, _address, _count), do: {:error, :invalid_table}

  @doc "data-model table に 1 個以上の値を書き込みます。"
  @spec put(server(), table(), non_neg_integer(), term() | [term()]) :: :ok | {:error, term()}
  def put(memory, table, address, values) when table in @tables do
    list = if is_list(values), do: values, else: [values]
    :gen_server.call(memory, {:put, table, address, list})
  end

  def put(_memory, _table, _address, _values), do: {:error, :invalid_table}

  @impl AVModbus.Server
  def handle_request(_unit_id, request, memory),
    do: :gen_server.call(memory, {:request, request})

  @impl :gen_server
  def init(state), do: {:ok, state}

  @impl :gen_server
  def handle_call({:get, table, address, count}, _from, state) do
    result =
      if inside?(state, table, address, count),
        do: read(state, table, address, count),
        else: {:error, :invalid_address_range}

    {:reply, result, state}
  end

  def handle_call({:put, table, address, values}, _from, state) do
    cond do
      not inside?(state, table, address, length(values)) ->
        {:reply, {:error, :invalid_address_range}, state}

      not valid_values?(table, values) ->
        {:reply, {:error, :invalid_value}, state}

      true ->
        {:reply, :ok, write(state, table, address, values)}
    end
  end

  def handle_call({:request, request}, _from, state) do
    {result, next_state} = request(state, request)
    {:reply, result, next_state}
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :unsupported_call}, state}

  @impl :gen_server
  def handle_cast(_message, state), do: {:noreply, state}

  defp request(state, {kind, address, count})
       when kind in [
              :read_coils,
              :read_discrete_inputs,
              :read_holding_registers,
              :read_input_registers
            ] do
    table = request_table(kind)

    if inside?(state, table, address, count),
      do: {{:ok, read(state, table, address, count)}, state},
      else: address_exception(state)
  end

  defp request(state, {:write_single_coil, address, value}),
    do: store(state, :coil, address, [value])

  defp request(state, {:write_single_register, address, value}),
    do: store(state, :holding_register, address, [value])

  defp request(state, {:write_multiple_coils, address, values}),
    do: store(state, :coil, address, values)

  defp request(state, {:write_multiple_registers, address, values}),
    do: store(state, :holding_register, address, values)

  defp request(state, {:mask_write_register, address, and_mask, or_mask}) do
    if inside?(state, :holding_register, address, 1) do
      [current] = read(state, :holding_register, address, 1)
      value = bor(band(current, and_mask), band(or_mask, band(bnot(and_mask), 0xFFFF)))
      {:ok, write(state, :holding_register, address, [value])}
    else
      address_exception(state)
    end
  end

  defp request(
         state,
         {:read_write_multiple_registers, read_address, read_count, write_address, values}
       ) do
    if inside?(state, :holding_register, read_address, read_count) and
         inside?(state, :holding_register, write_address, length(values)) do
      next_state = write(state, :holding_register, write_address, values)
      {{:ok, read(next_state, :holding_register, read_address, read_count)}, next_state}
    else
      address_exception(state)
    end
  end

  defp request(state, {:read_fifo_queue, address}) do
    if inside?(state, :holding_register, address, 1) do
      [count] = read(state, :holding_register, address, 1)

      cond do
        count > 31 ->
          {{:error, {:exception, :illegal_data_value}}, state}

        count == 0 ->
          {{:ok, []}, state}

        inside?(state, :holding_register, address + 1, count) ->
          {{:ok, read(state, :holding_register, address + 1, count)}, state}

        true ->
          address_exception(state)
      end
    else
      address_exception(state)
    end
  end

  defp request(state, {:read_file_record, groups}) when is_list(groups) do
    if valid_read_groups?(state, groups) do
      records = read_file_groups(state, groups, [])
      {{:ok, records}, state}
    else
      address_exception(state)
    end
  end

  defp request(state, {:write_file_record, groups}) when is_list(groups) do
    if valid_write_groups?(state, groups) do
      {:ok, write_file_groups(state, groups)}
    else
      address_exception(state)
    end
  end

  defp request(state, _request),
    do: {{:error, {:exception, :illegal_function}}, state}

  defp store(state, table, address, values) do
    if inside?(state, table, address, length(values)) and valid_values?(table, values),
      do: {:ok, write(state, table, address, values)},
      else: address_exception(state)
  end

  defp address_exception(state),
    do: {{:error, {:exception, :illegal_data_address}}, state}

  defp request_table(:read_coils), do: :coil
  defp request_table(:read_discrete_inputs), do: :discrete_input
  defp request_table(:read_holding_registers), do: :holding_register
  defp request_table(:read_input_registers), do: :input_register

  defp inside?(state, table, address, count) do
    is_integer(address) and address >= 0 and is_integer(count) and count >= 1 and
      address + count <= Map.get(state.sizes, table, 0)
  end

  defp read(state, table, address, count),
    do: read_values(state.data, table, address, count, blank(table), [])

  defp read_values(_data, _table, _address, 0, _blank, values), do: reverse(values, [])

  defp read_values(data, table, address, count, blank, values) do
    value = Map.get(data, {table, address}, blank)
    read_values(data, table, address + 1, count - 1, blank, [value | values])
  end

  defp blank(table) when table in [:coil, :discrete_input], do: false
  defp blank(_table), do: 0

  defp write(state, table, address, values),
    do: %{state | data: write_values(state.data, table, address, values)}

  defp write_values(data, _table, _address, []), do: data

  defp write_values(data, table, address, [value | values]) do
    write_values(Map.put(data, {table, address}, value), table, address + 1, values)
  end

  defp valid_values?(table, values) when table in [:coil, :discrete_input],
    do: all_booleans?(values)

  defp valid_values?(_table, values), do: all_words?(values)

  defp all_booleans?([]), do: true
  defp all_booleans?([value | values]) when is_boolean(value), do: all_booleans?(values)
  defp all_booleans?(_values), do: false

  defp all_words?([]), do: true

  defp all_words?([value | values])
       when is_integer(value) and value >= 0 and value <= 0xFFFF,
       do: all_words?(values)

  defp all_words?(_values), do: false

  defp valid_read_groups?(_state, []), do: false

  defp valid_read_groups?(state, [{file, record, count} | groups]) do
    file_record?(state, file, record, count) and valid_read_groups_tail?(state, groups)
  end

  defp valid_read_groups?(_state, _groups), do: false

  defp valid_read_groups_tail?(_state, []), do: true

  defp valid_read_groups_tail?(state, [{file, record, count} | groups]),
    do: file_record?(state, file, record, count) and valid_read_groups_tail?(state, groups)

  defp valid_read_groups_tail?(_state, _groups), do: false

  defp valid_write_groups?(_state, []), do: false

  defp valid_write_groups?(state, [{file, record, values} | groups]) when is_list(values) do
    file_record?(state, file, record, length(values)) and all_words?(values) and
      valid_write_groups_tail?(state, groups)
  end

  defp valid_write_groups?(_state, _groups), do: false

  defp valid_write_groups_tail?(_state, []), do: true

  defp valid_write_groups_tail?(state, [{file, record, values} | groups]) when is_list(values) do
    file_record?(state, file, record, length(values)) and all_words?(values) and
      valid_write_groups_tail?(state, groups)
  end

  defp valid_write_groups_tail?(_state, _groups), do: false

  defp file_record?(state, file, record, count) do
    is_integer(file) and file >= 1 and file <= state.files and is_integer(record) and record >= 0 and
      is_integer(count) and count >= 1 and record + count <= 10_000
  end

  defp read_file_groups(_state, [], records), do: reverse(records, [])

  defp read_file_groups(state, [{file, record, count} | groups], records) do
    values = read_file_values(state.data, file, record, count, [])
    read_file_groups(state, groups, [values | records])
  end

  defp read_file_values(_data, _file, _record, 0, values), do: reverse(values, [])

  defp read_file_values(data, file, record, count, values) do
    value = Map.get(data, {:file, file, record}, 0)
    read_file_values(data, file, record + 1, count - 1, [value | values])
  end

  defp write_file_groups(state, groups),
    do: %{state | data: write_file_group_values(state.data, groups)}

  defp write_file_group_values(data, []), do: data

  defp write_file_group_values(data, [{file, record, values} | groups]) do
    next_data = write_file_values(data, file, record, values)
    write_file_group_values(next_data, groups)
  end

  defp write_file_values(data, _file, _record, []), do: data

  defp write_file_values(data, file, record, [value | values]) do
    write_file_values(Map.put(data, {:file, file, record}, value), file, record + 1, values)
  end

  defp table_sizes(options) do
    with {:ok, coils} <- validate_size(option(options, :coils, 65_536), 65_536, :coils),
         {:ok, discrete} <-
           validate_size(option(options, :discrete_inputs, 65_536), 65_536, :discrete_inputs),
         {:ok, holding} <-
           validate_size(option(options, :holding_registers, 65_536), 65_536, :holding_registers),
         {:ok, input} <-
           validate_size(option(options, :input_registers, 65_536), 65_536, :input_registers) do
      {:ok,
       %{
         coil: coils,
         discrete_input: discrete,
         holding_register: holding,
         input_register: input
       }}
    end
  end

  defp validate_size(value, maximum, _key)
       when is_integer(value) and value >= 0 and value <= maximum,
       do: {:ok, value}

  defp validate_size(_value, _maximum, key), do: {:error, {:invalid_size, key}}

  defp validate_name(nil), do: {:ok, nil}
  defp validate_name(name) when is_atom(name), do: {:ok, name}
  defp validate_name(_name), do: {:error, :invalid_name_option}

  defp validate_options([]), do: :ok

  defp validate_options([{key, _value} | options])
       when key in [:coils, :discrete_inputs, :holding_registers, :input_registers, :files, :name],
       do: validate_options(options)

  defp validate_options([invalid | _options]), do: {:error, {:invalid_option, invalid}}

  defp option([], _key, default), do: default
  defp option([{key, value} | _options], key, _default), do: value
  defp option([_option | options], key, default), do: option(options, key, default)

  defp reverse([], reversed), do: reversed
  defp reverse([value | values], reversed), do: reverse(values, [value | reversed])
end
