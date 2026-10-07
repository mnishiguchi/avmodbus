defmodule AVModbus.PDU do
  @moduledoc """
  transport-independent な Modbus request / response codec です。

  request は tuple で表現し、同じ protocol core を client / server と RTU / ASCII で共有します。
  """

  import Bitwise

  @read_bits_max 2_000
  @read_registers_max 125
  @write_bits_max 1_968
  @write_registers_max 123
  @read_write_registers_max 121
  @fifo_max 31
  @event_log_max 64
  @file_records_max 10_000
  @diagnostic_one_word [1, 2, 3, 4, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20]
  @known_functions [1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 15, 16, 17, 20, 21, 22, 23, 24, 43]

  @type address :: 0..65_535
  @type word :: 0..65_535
  @type request ::
          {:read_coils, address(), pos_integer()}
          | {:read_discrete_inputs, address(), pos_integer()}
          | {:read_holding_registers, address(), pos_integer()}
          | {:read_input_registers, address(), pos_integer()}
          | {:write_single_coil, address(), boolean()}
          | {:write_single_register, address(), word()}
          | {:write_multiple_coils, address(), [boolean()]}
          | {:write_multiple_registers, address(), [word()]}
          | {:mask_write_register, address(), word(), word()}
          | {:read_write_multiple_registers, address(), pos_integer(), address(), [word()]}
          | :read_exception_status
          | {:diagnostics, word(), [word()]}
          | :get_comm_event_counter
          | :get_comm_event_log
          | :report_server_id
          | {:read_file_record, [{1..65_535, 0..9_999, pos_integer()}]}
          | {:write_file_record, [{1..65_535, 0..9_999, [word()]}]}
          | {:read_fifo_queue, address()}
          | {:read_device_identification, :basic | :regular | :extended | :individual, byte()}
          | {:encapsulated_interface_transport, byte(), binary()}
          | {:custom, 1..127, binary()}

  @type exception ::
          :illegal_function
          | :illegal_data_address
          | :illegal_data_value
          | :server_device_failure
          | :acknowledge
          | :server_device_busy
          | :memory_parity_error
          | :gateway_path_unavailable
          | :gateway_target_device_failed_to_respond
          | byte()

  @type result :: :ok | {:ok, term()} | {:error, {:exception, exception()}}

  @spec encode_request(request()) :: {:ok, binary()} | {:error, term()}
  def encode_request({:read_coils, address, quantity}) do
    encode_read(0x01, address, quantity, @read_bits_max)
  end

  def encode_request({:read_discrete_inputs, address, quantity}) do
    encode_read(0x02, address, quantity, @read_bits_max)
  end

  def encode_request({:read_holding_registers, address, quantity}) do
    encode_read(0x03, address, quantity, @read_registers_max)
  end

  def encode_request({:read_input_registers, address, quantity}) do
    encode_read(0x04, address, quantity, @read_registers_max)
  end

  def encode_request({:write_single_coil, address, value})
      when is_boolean(value) do
    with :ok <- validate_address(address) do
      encoded = if value, do: 0xFF00, else: 0x0000
      {:ok, <<0x05, address::16, encoded::16>>}
    end
  end

  def encode_request({:write_single_register, address, value}) do
    with :ok <- validate_address(address),
         :ok <- validate_word(value) do
      {:ok, <<0x06, address::16, value::16>>}
    end
  end

  def encode_request(:read_exception_status), do: {:ok, <<0x07>>}

  def encode_request({:diagnostics, 0, data}) do
    with :ok <- validate_word_list(data, 0, @read_registers_max) do
      encoded = encode_words(data, <<>>)
      {:ok, <<0x08, 0::16, encoded::binary>>}
    end
  end

  def encode_request({:diagnostics, sub_function, data})
      when sub_function in @diagnostic_one_word do
    with :ok <- validate_word_list(data, 1, 1) do
      encoded = encode_words(data, <<>>)
      {:ok, <<0x08, sub_function::16, encoded::binary>>}
    end
  end

  def encode_request({:diagnostics, _sub_function, _data}),
    do: {:error, :unsupported_diagnostics_sub_function}

  def encode_request(:get_comm_event_counter), do: {:ok, <<0x0B>>}
  def encode_request(:get_comm_event_log), do: {:ok, <<0x0C>>}

  def encode_request({:write_multiple_coils, address, values}) do
    with :ok <- validate_address(address),
         :ok <- validate_list(values, @write_bits_max),
         :ok <- validate_span(address, length(values)),
         true <- all_booleans?(values) || {:error, :invalid_coil_value} do
      packed = pack_bits(values)
      {:ok, <<0x0F, address::16, length(values)::16, byte_size(packed), packed::binary>>}
    end
  end

  def encode_request({:write_multiple_registers, address, values}) do
    with :ok <- validate_address(address),
         :ok <- validate_list(values, @write_registers_max),
         :ok <- validate_span(address, length(values)),
         true <- all_words?(values) || {:error, :invalid_register_value} do
      data = encode_words(values, <<>>)
      {:ok, <<0x10, address::16, length(values)::16, byte_size(data), data::binary>>}
    end
  end

  def encode_request({:mask_write_register, address, and_mask, or_mask}) do
    with :ok <- validate_address(address),
         :ok <- validate_word(and_mask),
         :ok <- validate_word(or_mask) do
      {:ok, <<0x16, address::16, and_mask::16, or_mask::16>>}
    end
  end

  def encode_request(
        {:read_write_multiple_registers, read_address, read_quantity, write_address, write_values}
      ) do
    with :ok <- validate_address(read_address),
         :ok <- validate_quantity(read_quantity, @read_registers_max),
         :ok <- validate_span(read_address, read_quantity),
         :ok <- validate_address(write_address),
         :ok <- validate_list(write_values, @read_write_registers_max),
         :ok <- validate_span(write_address, length(write_values)),
         true <- all_words?(write_values) || {:error, :invalid_register_value} do
      data = encode_words(write_values, <<>>)

      {:ok,
       <<0x17, read_address::16, read_quantity::16, write_address::16, length(write_values)::16,
         byte_size(data), data::binary>>}
    end
  end

  def encode_request(:report_server_id), do: {:ok, <<0x11>>}

  def encode_request({:read_file_record, groups}) when is_list(groups) do
    with {:ok, encoded, response_size} <- encode_read_file_groups(groups, <<>>, 0),
         true <- byte_size(encoded) > 0 || {:error, :invalid_quantity},
         true <- byte_size(encoded) <= 245 || {:error, :too_many_file_records},
         true <- response_size <= 245 || {:error, :too_many_file_records} do
      {:ok, <<0x14, byte_size(encoded), encoded::binary>>}
    end
  end

  def encode_request({:write_file_record, groups}) when is_list(groups) do
    with {:ok, encoded} <- encode_write_file_groups(groups, <<>>),
         true <- byte_size(encoded) > 0 || {:error, :invalid_quantity},
         true <- byte_size(encoded) <= 251 || {:error, :too_many_file_records} do
      {:ok, <<0x15, byte_size(encoded), encoded::binary>>}
    end
  end

  def encode_request({:read_fifo_queue, address}) do
    with :ok <- validate_address(address) do
      {:ok, <<0x18, address::16>>}
    end
  end

  def encode_request({:read_device_identification, category, object_id}) do
    with {:ok, category_code} <- device_id_category_code(category),
         :ok <- validate_byte(object_id) do
      {:ok, <<0x2B, 0x0E, category_code, object_id>>}
    end
  end

  def encode_request({:encapsulated_interface_transport, mei_type, data})
      when is_integer(mei_type) and mei_type >= 0 and mei_type <= 0xFF and mei_type != 0x0E and
             is_binary(data) and byte_size(data) <= 251 do
    {:ok, <<0x2B, mei_type, data::binary>>}
  end

  def encode_request({:custom, function, data})
      when is_integer(function) and function >= 1 and function <= 127 and is_binary(data) and
             byte_size(data) <= 252 do
    {:ok, <<function, data::binary>>}
  end

  def encode_request(_request), do: {:error, :unsupported_request}

  @doc """
  server 向け request PDU を decode / validate します。

  defined function で shape が不正な request は wire に返すべき Modbus exception を返します。
  undefined public function code は custom request として保持します。
  """
  @spec decode_request(binary()) :: {:ok, request()} | {:error, exception()}
  def decode_request(<<function, data::binary>>)
      when function >= 1 and function <= 127 and byte_size(data) <= 252 do
    decode_request_data(function, data)
  end

  def decode_request(<<function, _data::binary>>) when function >= 1 and function <= 127,
    do: {:error, :illegal_data_value}

  def decode_request(_pdu), do: {:error, :illegal_function}

  @doc """
  server handler result を response PDU に encode します。

  returned value count や write echo を request と照合し、invalid handler result は wire に出しません。
  """
  @spec encode_response(request(), result()) :: {:ok, binary()} | {:error, term()}
  def encode_response(request, {:error, {:exception, exception}}) do
    with {:ok, function} <- function(request) do
      encode_exception(function, exception)
    end
  end

  def encode_response({kind, _address, quantity} = request, {:ok, values})
      when kind in [:read_coils, :read_discrete_inputs] do
    with true <- is_list(values) and length(values) == quantity,
         true <- all_booleans?(values),
         {:ok, function} <- function(request) do
      data = pack_bits(values)
      {:ok, <<function, byte_size(data), data::binary>>}
    else
      _other -> {:error, :invalid_handler_result}
    end
  end

  def encode_response({kind, _address, quantity} = request, {:ok, values})
      when kind in [:read_holding_registers, :read_input_registers] do
    with true <- is_list(values) and length(values) == quantity,
         true <- all_words?(values),
         {:ok, function} <- function(request) do
      data = encode_words(values, <<>>)
      {:ok, <<function, byte_size(data), data::binary>>}
    else
      _other -> {:error, :invalid_handler_result}
    end
  end

  def encode_response({kind, _address, _value} = request, :ok)
      when kind in [:write_single_coil, :write_single_register],
      do: encode_request(request)

  def encode_response(:read_exception_status, {:ok, status}) do
    with :ok <- validate_byte(status), do: {:ok, <<0x07, status>>}
  end

  def encode_response({:diagnostics, sub_function, _request_data}, {:ok, data}) do
    limits = if sub_function in @diagnostic_one_word, do: {1, 1}, else: {0, @read_registers_max}
    {minimum, maximum} = limits

    with :ok <- validate_word_list(data, minimum, maximum) do
      encoded = encode_words(data, <<>>)
      {:ok, <<0x08, sub_function::16, encoded::binary>>}
    else
      _error -> {:error, :invalid_handler_result}
    end
  end

  def encode_response(:get_comm_event_counter, {:ok, result}) when is_map(result) do
    with {:ok, status} <- fetch_word(result, :status),
         {:ok, event_count} <- fetch_word(result, :event_count) do
      {:ok, <<0x0B, status::16, event_count::16>>}
    else
      _error -> {:error, :invalid_handler_result}
    end
  end

  def encode_response(:get_comm_event_log, {:ok, result}) when is_map(result) do
    events = Map.get(result, :events)

    with {:ok, status} <- fetch_word(result, :status),
         {:ok, event_count} <- fetch_word(result, :event_count),
         {:ok, message_count} <- fetch_word(result, :message_count),
         true <- is_list(events) and length(events) <= @event_log_max,
         true <- all_bytes?(events) do
      encoded_events = encode_bytes(events, <<>>)

      {:ok,
       <<0x0C, byte_size(encoded_events) + 6, status::16, event_count::16, message_count::16,
         encoded_events::binary>>}
    else
      _error -> {:error, :invalid_handler_result}
    end
  end

  def encode_response({kind, address, values}, :ok)
      when kind in [:write_multiple_coils, :write_multiple_registers] do
    function = if kind == :write_multiple_coils, do: 0x0F, else: 0x10
    {:ok, <<function, address::16, length(values)::16>>}
  end

  def encode_response(:report_server_id, {:ok, data})
      when is_binary(data) and byte_size(data) <= 251,
      do: {:ok, <<0x11, byte_size(data), data::binary>>}

  def encode_response({:read_file_record, groups}, {:ok, records})
      when is_list(records) and length(records) == length(groups) do
    with {:ok, data} <- encode_read_file_response(groups, records, <<>>),
         true <- byte_size(data) <= 251 do
      {:ok, <<0x14, byte_size(data), data::binary>>}
    else
      _error -> {:error, :invalid_handler_result}
    end
  end

  def encode_response({:write_file_record, _groups} = request, :ok), do: encode_request(request)
  def encode_response({:mask_write_register, _, _, _} = request, :ok), do: encode_request(request)

  def encode_response(
        {:read_write_multiple_registers, _read, quantity, _write, _values},
        {:ok, values}
      ) do
    with true <- is_list(values) and length(values) == quantity,
         true <- all_words?(values) do
      data = encode_words(values, <<>>)
      {:ok, <<0x17, byte_size(data), data::binary>>}
    else
      _other -> {:error, :invalid_handler_result}
    end
  end

  def encode_response({:read_fifo_queue, _address}, {:ok, values}) do
    with true <- is_list(values) and length(values) <= @fifo_max,
         true <- all_words?(values) do
      data = encode_words(values, <<>>)
      {:ok, <<0x18, byte_size(data) + 2::16, length(values)::16, data::binary>>}
    else
      _other -> {:error, :invalid_handler_result}
    end
  end

  def encode_response({:read_device_identification, category, _object_id}, {:ok, answer})
      when is_map(answer) do
    with {:ok, category_code} <- device_id_category_code(category),
         {:ok, conformity} <- fetch_byte(answer, :conformity_level),
         {:ok, more_follows} <- fetch_boolean(answer, :more_follows),
         {:ok, next_object_id} <- fetch_byte(answer, :next_object_id),
         {:ok, objects} <- fetch_identification_objects(answer),
         {:ok, encoded_objects} <- encode_identification_objects(objects, <<>>),
         true <- length(objects) <= 255,
         true <- byte_size(encoded_objects) <= 246 do
      more = if more_follows, do: 0xFF, else: 0x00

      {:ok,
       <<0x2B, 0x0E, category_code, conformity, more, next_object_id, length(objects),
         encoded_objects::binary>>}
    else
      _error -> {:error, :invalid_handler_result}
    end
  end

  def encode_response({:encapsulated_interface_transport, mei_type, _request_data}, {:ok, data})
      when is_binary(data) and byte_size(data) <= 251,
      do: {:ok, <<0x2B, mei_type, data::binary>>}

  def encode_response({:custom, function, _request_data}, {:ok, data})
      when is_binary(data) and byte_size(data) <= 252,
      do: {:ok, <<function, data::binary>>}

  def encode_response(_request, _result), do: {:error, :invalid_handler_result}

  @doc "request function code に対する Modbus exception response を encode します。"
  @spec encode_exception(byte(), exception()) :: {:ok, binary()} | {:error, term()}
  def encode_exception(function, exception)
      when is_integer(function) and function >= 0 and function <= 255 do
    case exception_code(exception) do
      {:ok, code} -> {:ok, <<exception_function(function), code>>}
      error -> error
    end
  end

  def encode_exception(_function, _exception), do: {:error, :invalid_function}

  defp exception_function(function) when function < 0x80, do: bor(function, 0x80)
  defp exception_function(function), do: function

  @doc false
  @spec request_length(binary()) :: {:ok, pos_integer()} | :more | :unknown | :invalid
  def request_length(<<function, _rest::binary>>) when function == 0 or function >= 0x80,
    do: :invalid

  def request_length(<<function, _rest::binary>>) when function in 1..6, do: {:ok, 5}
  def request_length(<<function, _rest::binary>>) when function in [7, 11, 12, 17], do: {:ok, 1}

  def request_length(<<0x08, sub_function::16, _rest::binary>>)
      when sub_function in @diagnostic_one_word,
      do: {:ok, 5}

  def request_length(<<0x08, _sub_function::16, _rest::binary>>), do: :unknown

  def request_length(<<function, _address::16, _quantity::16, byte_count, _rest::binary>>)
      when function in [0x0F, 0x10],
      do: {:ok, byte_count + 6}

  def request_length(<<function, byte_count, _rest::binary>>)
      when function in [0x14, 0x15],
      do: {:ok, byte_count + 2}

  def request_length(<<0x16, _rest::binary>>), do: {:ok, 7}

  def request_length(
        <<0x17, _read_address::16, _read_quantity::16, _write_address::16, _write_quantity::16,
          byte_count, _rest::binary>>
      ),
      do: {:ok, byte_count + 10}

  def request_length(<<0x18, _rest::binary>>), do: {:ok, 3}
  def request_length(<<0x2B, 0x0E, _rest::binary>>), do: {:ok, 4}
  def request_length(<<0x2B, _mei_type, _rest::binary>>), do: :unknown

  def request_length(<<function, _rest::binary>>)
      when function in [0x08, 0x0F, 0x10, 0x14, 0x15, 0x17, 0x2B],
      do: :more

  def request_length(<<>>), do: :more
  def request_length(_pdu), do: :unknown

  @doc """
  request を serial-line broadcast unit `0` に送信できるか返します。

  server は unit `0` に response を返さないため、read component を含む request は broadcast できません。
  """
  @spec broadcast_request?(request()) :: boolean()
  def broadcast_request?({:write_single_coil, _, _}), do: true
  def broadcast_request?({:write_single_register, _, _}), do: true
  def broadcast_request?({:write_multiple_coils, _, _}), do: true
  def broadcast_request?({:write_multiple_registers, _, _}), do: true
  def broadcast_request?({:write_file_record, _}), do: true
  def broadcast_request?({:mask_write_register, _, _, _}), do: true
  def broadcast_request?({:custom, _, _}), do: true
  def broadcast_request?(_request), do: false

  @doc "response PDU を request と照合して decode します。"
  @spec decode_response(request(), binary()) :: {:ok, term()} | :ok | {:error, term()}
  def decode_response(request, pdu) when is_binary(pdu) do
    case decode_response_data(request, pdu) do
      {:error, {:exception, _exception}} = error -> error
      {:error, _reason} -> {:error, {:invalid_response, pdu}}
      result -> result
    end
  end

  def decode_response(_request, pdu), do: {:error, {:invalid_response, pdu}}

  defp decode_response_data(request, <<function, exception_code>>) when function >= 0x80 do
    case function(request) do
      {:ok, expected} when function == expected + 0x80 ->
        {:error, {:exception, exception(exception_code)}}

      {:ok, expected} ->
        {:error, {:unexpected_function, function, expected}}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_response_data(:read_exception_status, <<0x07, status>>), do: {:ok, status}

  defp decode_response_data({:diagnostics, sub_function, request_data}, pdu) do
    expected_bytes = if sub_function == 0, do: length(request_data) * 2, else: 2

    case pdu do
      <<0x08, ^sub_function::16, data::binary-size(expected_bytes)>> ->
        {:ok, decode_words(data, [])}

      <<function, _rest::binary>> when function != 0x08 ->
        {:error, {:unexpected_function, function, 0x08}}

      _other ->
        {:error, :malformed_response}
    end
  end

  defp decode_response_data(:get_comm_event_counter, pdu) do
    case pdu do
      <<0x0B, status::16, event_count::16>> ->
        {:ok, %{status: status, event_count: event_count}}

      <<function, _rest::binary>> when function != 0x0B ->
        {:error, {:unexpected_function, function, 0x0B}}

      _other ->
        {:error, :malformed_response}
    end
  end

  defp decode_response_data(:get_comm_event_log, pdu) do
    case pdu do
      <<0x0C, byte_count, status::16, event_count::16, message_count::16, events::binary>>
      when byte_count == byte_size(events) + 6 and byte_size(events) <= @event_log_max ->
        {:ok,
         %{
           status: status,
           event_count: event_count,
           message_count: message_count,
           events: decode_bytes(events, [])
         }}

      <<function, _rest::binary>> when function != 0x0C ->
        {:error, {:unexpected_function, function, 0x0C}}

      _other ->
        {:error, :malformed_response}
    end
  end

  defp decode_response_data({kind, _address, quantity}, pdu)
       when kind in [:read_coils, :read_discrete_inputs] do
    expected_function = if kind == :read_coils, do: 0x01, else: 0x02
    expected_bytes = div(quantity + 7, 8)

    case pdu do
      <<^expected_function, ^expected_bytes, data::binary-size(expected_bytes)>> ->
        {:ok, unpack_bits(data, quantity, [])}

      <<function, _rest::binary>> when function != expected_function ->
        {:error, {:unexpected_function, function, expected_function}}

      _other ->
        {:error, :malformed_response}
    end
  end

  defp decode_response_data({kind, _address, quantity}, pdu)
       when kind in [:read_holding_registers, :read_input_registers] do
    expected_function = if kind == :read_holding_registers, do: 0x03, else: 0x04
    expected_bytes = quantity * 2

    case pdu do
      <<^expected_function, ^expected_bytes, data::binary-size(expected_bytes)>> ->
        {:ok, decode_words(data, [])}

      <<function, _rest::binary>> when function != expected_function ->
        {:error, {:unexpected_function, function, expected_function}}

      _other ->
        {:error, :malformed_response}
    end
  end

  defp decode_response_data({kind, _address, _value} = request, pdu)
       when kind in [:write_single_coil, :write_single_register] do
    decode_echo(request, pdu)
  end

  defp decode_response_data({kind, address, values}, pdu)
       when kind in [:write_multiple_coils, :write_multiple_registers] do
    expected_function = if kind == :write_multiple_coils, do: 0x0F, else: 0x10
    quantity = length(values)

    case pdu do
      <<^expected_function, ^address::16, ^quantity::16>> ->
        :ok

      <<function, _rest::binary>> when function != expected_function ->
        {:error, {:unexpected_function, function, expected_function}}

      _other ->
        {:error, :response_does_not_match_request}
    end
  end

  defp decode_response_data(
         {:mask_write_register, _address, _and_mask, _or_mask} = request,
         pdu
       ) do
    decode_echo(request, pdu)
  end

  defp decode_response_data(
         {:read_write_multiple_registers, _read_address, read_quantity, _write_address,
          _write_values},
         pdu
       ) do
    expected_bytes = read_quantity * 2

    case pdu do
      <<0x17, ^expected_bytes, data::binary-size(expected_bytes)>> ->
        {:ok, decode_words(data, [])}

      <<function, _rest::binary>> when function != 0x17 ->
        {:error, {:unexpected_function, function, 0x17}}

      _other ->
        {:error, :malformed_response}
    end
  end

  defp decode_response_data(:report_server_id, pdu) do
    case pdu do
      <<0x11, byte_count, data::binary-size(byte_count)>> ->
        {:ok, data}

      <<function, _rest::binary>> when function != 0x11 ->
        {:error, {:unexpected_function, function, 0x11}}

      _other ->
        {:error, :malformed_response}
    end
  end

  defp decode_response_data({:read_file_record, groups}, pdu) do
    case pdu do
      <<0x14, byte_count, data::binary-size(byte_count)>> ->
        decode_file_records(groups, data, [])

      <<function, _rest::binary>> when function != 0x14 ->
        {:error, {:unexpected_function, function, 0x14}}

      _other ->
        {:error, :malformed_response}
    end
  end

  defp decode_response_data({:write_file_record, _groups} = request, pdu) do
    decode_echo(request, pdu)
  end

  defp decode_response_data({:read_fifo_queue, _address}, pdu) do
    case pdu do
      <<0x18, byte_count::16, fifo_count::16, data::binary-size(fifo_count * 2)>>
      when byte_count == fifo_count * 2 + 2 and fifo_count <= @fifo_max ->
        {:ok, decode_words(data, [])}

      <<function, _rest::binary>> when function != 0x18 ->
        {:error, {:unexpected_function, function, 0x18}}

      _other ->
        {:error, :malformed_response}
    end
  end

  defp decode_response_data({:read_device_identification, category, _object_id}, pdu) do
    with {:ok, category_code} <- device_id_category_code(category) do
      case pdu do
        <<0x2B, 0x0E, ^category_code, conformity_level, more_follows, next_object_id,
          object_count, objects::binary>>
        when more_follows in [0x00, 0xFF] ->
          case decode_device_id_objects(objects, object_count, []) do
            {:ok, decoded_objects} ->
              {:ok,
               %{
                 conformity_level: conformity_level,
                 more_follows: more_follows == 0xFF,
                 next_object_id: next_object_id,
                 objects: decoded_objects
               }}

            :error ->
              {:error, :malformed_response}
          end

        <<function, _rest::binary>> when function != 0x2B ->
          {:error, {:unexpected_function, function, 0x2B}}

        _other ->
          {:error, :malformed_response}
      end
    end
  end

  defp decode_response_data({:encapsulated_interface_transport, mei_type, _request_data}, pdu) do
    case pdu do
      <<0x2B, ^mei_type, data::binary>> ->
        {:ok, data}

      <<function, _rest::binary>> when function != 0x2B ->
        {:error, {:unexpected_function, function, 0x2B}}

      _other ->
        {:error, :malformed_response}
    end
  end

  defp decode_response_data({:custom, expected_function, _request_data}, pdu) do
    case pdu do
      <<^expected_function, data::binary>> ->
        {:ok, data}

      <<function, _rest::binary>> ->
        {:error, {:unexpected_function, function, expected_function}}

      _other ->
        {:error, :malformed_response}
    end
  end

  defp decode_response_data(request, pdu) do
    case function(request) do
      {:ok, expected_function} ->
        case pdu do
          <<function, _rest::binary>> when function != expected_function ->
            {:error, {:unexpected_function, function, expected_function}}

          _other ->
            {:error, :malformed_response}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  partial response から expected PDU length を返します。

  RTU stream parser は sub-millisecond の inter-frame silent interval scheduling に依存せず
  frame boundary を判定できます。
  """
  @spec response_length(request(), binary()) :: {:ok, pos_integer()} | :more | :unknown | :invalid
  def response_length(request, partial_pdu) do
    with {:ok, expected_function} <- function(request) do
      response_length_for(request, expected_function, partial_pdu)
    else
      _error -> :invalid
    end
  end

  @spec function(request()) :: {:ok, 1..127} | {:error, :unsupported_request}
  def function({:read_coils, _, _}), do: {:ok, 0x01}
  def function({:read_discrete_inputs, _, _}), do: {:ok, 0x02}
  def function({:read_holding_registers, _, _}), do: {:ok, 0x03}
  def function({:read_input_registers, _, _}), do: {:ok, 0x04}
  def function({:write_single_coil, _, _}), do: {:ok, 0x05}
  def function({:write_single_register, _, _}), do: {:ok, 0x06}
  def function(:read_exception_status), do: {:ok, 0x07}
  def function({:diagnostics, _, _}), do: {:ok, 0x08}
  def function(:get_comm_event_counter), do: {:ok, 0x0B}
  def function(:get_comm_event_log), do: {:ok, 0x0C}
  def function({:write_multiple_coils, _, _}), do: {:ok, 0x0F}
  def function({:write_multiple_registers, _, _}), do: {:ok, 0x10}
  def function(:report_server_id), do: {:ok, 0x11}
  def function({:read_file_record, _}), do: {:ok, 0x14}
  def function({:write_file_record, _}), do: {:ok, 0x15}
  def function({:mask_write_register, _, _, _}), do: {:ok, 0x16}
  def function({:read_write_multiple_registers, _, _, _, _}), do: {:ok, 0x17}
  def function({:read_fifo_queue, _}), do: {:ok, 0x18}
  def function({:read_device_identification, _, _}), do: {:ok, 0x2B}
  def function({:encapsulated_interface_transport, _, _}), do: {:ok, 0x2B}

  def function({:custom, function, _}) when is_integer(function) and function in 1..127,
    do: {:ok, function}

  def function(_request), do: {:error, :unsupported_request}

  # Compatibility helper for the initial function-0x03 experiment.
  def read_holding_registers(address, quantity) do
    encode_request({:read_holding_registers, address, quantity})
  end

  defp decode_request_data(0x01, <<address::16, quantity::16>>)
       when quantity >= 1 and quantity <= @read_bits_max,
       do: {:ok, {:read_coils, address, quantity}}

  defp decode_request_data(0x02, <<address::16, quantity::16>>)
       when quantity >= 1 and quantity <= @read_bits_max,
       do: {:ok, {:read_discrete_inputs, address, quantity}}

  defp decode_request_data(0x03, <<address::16, quantity::16>>)
       when quantity >= 1 and quantity <= @read_registers_max,
       do: {:ok, {:read_holding_registers, address, quantity}}

  defp decode_request_data(0x04, <<address::16, quantity::16>>)
       when quantity >= 1 and quantity <= @read_registers_max,
       do: {:ok, {:read_input_registers, address, quantity}}

  defp decode_request_data(0x05, <<address::16, value::16>>) when value in [0x0000, 0xFF00],
    do: {:ok, {:write_single_coil, address, value == 0xFF00}}

  defp decode_request_data(0x06, <<address::16, value::16>>),
    do: {:ok, {:write_single_register, address, value}}

  defp decode_request_data(0x07, <<>>), do: {:ok, :read_exception_status}

  defp decode_request_data(0x08, <<sub_function::16, data::binary>>) do
    valid_size =
      if sub_function in @diagnostic_one_word,
        do: byte_size(data) == 2,
        else: rem(byte_size(data), 2) == 0

    if valid_size,
      do: {:ok, {:diagnostics, sub_function, decode_words(data, [])}},
      else: {:error, :illegal_data_value}
  end

  defp decode_request_data(0x0B, <<>>), do: {:ok, :get_comm_event_counter}
  defp decode_request_data(0x0C, <<>>), do: {:ok, :get_comm_event_log}

  defp decode_request_data(
         0x0F,
         <<address::16, quantity::16, byte_count, data::binary-size(byte_count)>>
       )
       when quantity >= 1 and quantity <= @write_bits_max and
              byte_count == div(quantity + 7, 8),
       do: {:ok, {:write_multiple_coils, address, unpack_bits(data, quantity, [])}}

  defp decode_request_data(
         0x10,
         <<address::16, quantity::16, byte_count, data::binary-size(byte_count)>>
       )
       when quantity >= 1 and quantity <= @write_registers_max and byte_count == quantity * 2,
       do: {:ok, {:write_multiple_registers, address, decode_words(data, [])}}

  defp decode_request_data(0x11, <<>>), do: {:ok, :report_server_id}

  defp decode_request_data(0x14, <<byte_count, data::binary-size(byte_count)>>)
       when byte_count >= 7 and byte_count <= 245 and rem(byte_count, 7) == 0 do
    with {:ok, groups, response_size} <- decode_read_file_groups(data, [], 0),
         true <- response_size <= 245 || {:error, :illegal_data_value} do
      {:ok, {:read_file_record, groups}}
    end
  end

  defp decode_request_data(0x15, <<byte_count, data::binary-size(byte_count)>>)
       when byte_count >= 9 and byte_count <= 251 do
    with {:ok, groups} <- decode_write_file_groups(data, []) do
      {:ok, {:write_file_record, groups}}
    end
  end

  defp decode_request_data(0x16, <<address::16, and_mask::16, or_mask::16>>),
    do: {:ok, {:mask_write_register, address, and_mask, or_mask}}

  defp decode_request_data(
         0x17,
         <<read_address::16, read_quantity::16, write_address::16, write_quantity::16, byte_count,
           data::binary-size(byte_count)>>
       )
       when read_quantity >= 1 and read_quantity <= @read_registers_max and write_quantity >= 1 and
              write_quantity <= @read_write_registers_max and byte_count == write_quantity * 2,
       do:
         {:ok,
          {:read_write_multiple_registers, read_address, read_quantity, write_address,
           decode_words(data, [])}}

  defp decode_request_data(0x18, <<address::16>>), do: {:ok, {:read_fifo_queue, address}}

  defp decode_request_data(0x2B, <<0x0E, category_code, object_id>>)
       when category_code in 1..4 do
    category =
      case category_code do
        1 -> :basic
        2 -> :regular
        3 -> :extended
        4 -> :individual
      end

    {:ok, {:read_device_identification, category, object_id}}
  end

  defp decode_request_data(0x2B, <<mei_type, data::binary>>) when mei_type != 0x0E,
    do: {:ok, {:encapsulated_interface_transport, mei_type, data}}

  defp decode_request_data(function, _data) when function in @known_functions,
    do: {:error, :illegal_data_value}

  defp decode_request_data(function, data), do: {:ok, {:custom, function, data}}

  defp decode_read_file_groups(<<>>, groups, response_size),
    do: {:ok, reverse(groups, []), response_size}

  defp decode_read_file_groups(
         <<0x06, file::16, record::16, quantity::16, rest::binary>>,
         groups,
         response_size
       )
       when file >= 1 and quantity >= 1 and record + quantity <= @file_records_max do
    decode_read_file_groups(
      rest,
      [{file, record, quantity} | groups],
      response_size + quantity * 2 + 2
    )
  end

  defp decode_read_file_groups(
         <<0x06, _file::16, _record::16, quantity::16, _rest::binary>>,
         _groups,
         _response_size
       )
       when quantity >= 1,
       do: {:error, :illegal_data_address}

  defp decode_read_file_groups(<<type, _rest::binary>>, _groups, _response_size)
       when type != 0x06,
       do: {:error, :illegal_data_address}

  defp decode_read_file_groups(_data, _groups, _response_size),
    do: {:error, :illegal_data_value}

  defp decode_write_file_groups(<<>>, groups), do: {:ok, reverse(groups, [])}

  defp decode_write_file_groups(
         <<0x06, file::16, record::16, quantity::16, data::binary-size(quantity * 2),
           rest::binary>>,
         groups
       )
       when file >= 1 and quantity >= 1 and quantity <= 122 and
              record + quantity <= @file_records_max do
    decode_write_file_groups(rest, [
      {file, record, decode_words(data, [])} | groups
    ])
  end

  defp decode_write_file_groups(
         <<0x06, _file::16, _record::16, quantity::16, _data::binary-size(quantity * 2),
           _rest::binary>>,
         _groups
       )
       when quantity >= 1,
       do: {:error, :illegal_data_address}

  defp decode_write_file_groups(<<type, _rest::binary>>, _groups) when type != 0x06,
    do: {:error, :illegal_data_address}

  defp decode_write_file_groups(_data, _groups), do: {:error, :illegal_data_value}

  defp encode_read_file_response([], [], encoded), do: {:ok, encoded}

  defp encode_read_file_response(
         [{_file, _record, quantity} | groups],
         [values | records],
         encoded
       ) do
    with true <- is_list(values) and length(values) == quantity,
         true <- all_words?(values) do
      data = encode_words(values, <<>>)

      encode_read_file_response(
        groups,
        records,
        <<encoded::binary, byte_size(data) + 1, 0x06, data::binary>>
      )
    else
      _other -> {:error, :invalid_handler_result}
    end
  end

  defp encode_read_file_response(_groups, _records, _encoded),
    do: {:error, :invalid_handler_result}

  defp fetch_word(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> if validate_word(value) == :ok, do: {:ok, value}, else: :error
      :error -> :error
    end
  end

  defp fetch_byte(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> if validate_byte(value) == :ok, do: {:ok, value}, else: :error
      :error -> :error
    end
  end

  defp fetch_boolean(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp fetch_identification_objects(map) do
    case Map.fetch(map, :objects) do
      {:ok, objects} when is_list(objects) -> {:ok, objects}
      _other -> :error
    end
  end

  defp encode_identification_objects([], encoded), do: {:ok, encoded}

  defp encode_identification_objects([{id, value} | objects], encoded)
       when is_integer(id) and id >= 0 and id <= 255 and is_binary(value) and
              byte_size(value) <= 255 do
    encode_identification_objects(
      objects,
      <<encoded::binary, id, byte_size(value), value::binary>>
    )
  end

  defp encode_identification_objects(_objects, _encoded), do: {:error, :invalid_object}

  defp encode_read(function, address, quantity, maximum) do
    with :ok <- validate_address(address),
         :ok <- validate_quantity(quantity, maximum),
         :ok <- validate_span(address, quantity) do
      {:ok, <<function, address::16, quantity::16>>}
    end
  end

  defp decode_echo(request, pdu) do
    with {:ok, expected_pdu} <- encode_request(request),
         {:ok, expected_function} <- function(request) do
      case pdu do
        ^expected_pdu ->
          :ok

        <<function, _rest::binary>> when function != expected_function ->
          {:error, {:unexpected_function, function, expected_function}}

        _other ->
          {:error, :response_does_not_match_request}
      end
    end
  end

  defp response_length_for(_request, expected, <<function, _code, _rest::binary>>)
       when function == expected + 0x80,
       do: {:ok, 2}

  defp response_length_for(_request, expected, <<function>>)
       when function == expected + 0x80,
       do: :more

  defp response_length_for(_request, expected, <<function, _rest::binary>>)
       when function != expected,
       do: :invalid

  defp response_length_for({kind, _, _}, _expected, <<_function, byte_count, _rest::binary>>)
       when kind in [
              :read_coils,
              :read_discrete_inputs,
              :read_holding_registers,
              :read_input_registers
            ],
       do: {:ok, byte_count + 2}

  defp response_length_for(
         :get_comm_event_log,
         _expected,
         <<_function, byte_count, _rest::binary>>
       ),
       do: {:ok, byte_count + 2}

  defp response_length_for(
         :report_server_id,
         _expected,
         <<_function, byte_count, _rest::binary>>
       ),
       do: {:ok, byte_count + 2}

  defp response_length_for(
         {kind, _groups},
         _expected,
         <<_function, byte_count, _rest::binary>>
       )
       when kind in [:read_file_record, :write_file_record],
       do: {:ok, byte_count + 2}

  defp response_length_for(
         {:read_write_multiple_registers, _, _, _, _},
         _expected,
         <<_function, byte_count, _rest::binary>>
       ),
       do: {:ok, byte_count + 2}

  defp response_length_for(
         {:read_fifo_queue, _},
         _expected,
         <<_function, byte_count::16, _rest::binary>>
       ),
       do: {:ok, byte_count + 3}

  defp response_length_for({kind, _, _}, _expected, <<_function, _rest::binary>>)
       when kind in [
              :write_single_coil,
              :write_single_register,
              :write_multiple_coils,
              :write_multiple_registers
            ],
       do: {:ok, 5}

  defp response_length_for(:get_comm_event_counter, _expected, <<_function, _rest::binary>>),
    do: {:ok, 5}

  defp response_length_for(:read_exception_status, _expected, <<_function, _rest::binary>>),
    do: {:ok, 2}

  defp response_length_for(
         {:diagnostics, 0, data},
         _expected,
         <<_function, _rest::binary>>
       ),
       do: {:ok, 3 + length(data) * 2}

  defp response_length_for(
         {:diagnostics, sub_function, _data},
         _expected,
         <<_function, _rest::binary>>
       )
       when sub_function in @diagnostic_one_word,
       do: {:ok, 5}

  defp response_length_for(
         {:mask_write_register, _, _, _},
         _expected,
         <<_function, _rest::binary>>
       ),
       do: {:ok, 7}

  defp response_length_for(
         {:read_device_identification, _, _},
         _expected,
         <<_function, 0x0E, rest::binary>>
       ),
       do: device_identification_length(rest)

  defp response_length_for(
         {:read_device_identification, _, _},
         _expected,
         <<_function, mei_type, _rest::binary>>
       )
       when mei_type != 0x0E,
       do: :invalid

  defp response_length_for(
         {:encapsulated_interface_transport, _, _},
         _expected,
         <<_function, _rest::binary>>
       ),
       do: :unknown

  defp response_length_for({:custom, _, _}, _expected, <<_function, _rest::binary>>),
    do: :unknown

  defp response_length_for(_request, _expected, _partial_pdu), do: :more

  defp device_identification_length(
         <<_category, _conformity, _more_follows, _next_object, object_count, objects::binary>>
       ) do
    device_id_objects_length(objects, object_count, 7)
  end

  defp device_identification_length(_partial), do: :more

  defp device_id_objects_length(_objects, 0, length), do: {:ok, length}

  defp device_id_objects_length(
         <<_object_id, size, _value::binary-size(size), rest::binary>>,
         count,
         length
       ) do
    device_id_objects_length(rest, count - 1, length + size + 2)
  end

  defp device_id_objects_length(_objects, _count, _length), do: :more

  defp validate_address(value) when is_integer(value) and value >= 0 and value <= 0xFFFF, do: :ok
  defp validate_address(_value), do: {:error, :invalid_address}

  defp validate_quantity(value, maximum)
       when is_integer(value) and value >= 1 and value <= maximum,
       do: :ok

  defp validate_quantity(_value, _maximum), do: {:error, :invalid_quantity}

  defp validate_span(address, quantity) when address + quantity <= 0x10000, do: :ok
  defp validate_span(_address, _quantity), do: {:error, :invalid_address_range}

  defp validate_word(value) when is_integer(value) and value >= 0 and value <= 0xFFFF, do: :ok
  defp validate_word(_value), do: {:error, :invalid_register_value}

  defp validate_byte(value) when is_integer(value) and value >= 0 and value <= 0xFF, do: :ok
  defp validate_byte(_value), do: {:error, :invalid_byte}

  defp validate_list(values, maximum)
       when is_list(values) and values != [] and length(values) <= maximum,
       do: :ok

  defp validate_list(_values, _maximum), do: {:error, :invalid_quantity}

  defp validate_word_list(values, minimum, maximum) when is_list(values) do
    count = length(values)

    cond do
      count < minimum or count > maximum -> {:error, :invalid_quantity}
      all_words?(values) -> :ok
      true -> {:error, :invalid_register_value}
    end
  end

  defp validate_word_list(_values, _minimum, _maximum), do: {:error, :invalid_quantity}

  defp encode_read_file_groups([], encoded, response_size),
    do: {:ok, encoded, response_size}

  defp encode_read_file_groups([{file, record, count} | rest], encoded, response_size) do
    with :ok <- validate_file_record(file, record, count) do
      encode_read_file_groups(
        rest,
        <<encoded::binary, 0x06, file::16, record::16, count::16>>,
        response_size + 2 + count * 2
      )
    end
  end

  defp encode_read_file_groups(_groups, _encoded, _response_size),
    do: {:error, :invalid_file_record}

  defp encode_write_file_groups([], encoded), do: {:ok, encoded}

  defp encode_write_file_groups([{file, record, values} | rest], encoded) do
    count = if is_list(values), do: length(values), else: 0

    with :ok <- validate_word_list(values, 1, 122),
         :ok <- validate_file_record(file, record, count) do
      data = encode_words(values, <<>>)

      encode_write_file_groups(
        rest,
        <<encoded::binary, 0x06, file::16, record::16, count::16, data::binary>>
      )
    end
  end

  defp encode_write_file_groups(_groups, _encoded), do: {:error, :invalid_file_record}

  defp validate_file_record(file, record, count)
       when is_integer(file) and file >= 1 and file <= 0xFFFF and is_integer(record) and
              record >= 0 and is_integer(count) and count >= 1 and
              record + count <= @file_records_max,
       do: :ok

  defp validate_file_record(_file, _record, _count), do: {:error, :invalid_file_record}

  defp decode_file_records([], <<>>, records), do: {:ok, reverse(records, [])}

  defp decode_file_records(
         [{_file, _record, count} | groups],
         <<sub_length, 0x06, data::binary>>,
         records
       )
       when sub_length == count * 2 + 1 and byte_size(data) >= count * 2 do
    data_size = count * 2
    <<values::binary-size(data_size), rest::binary>> = data
    decode_file_records(groups, rest, [decode_words(values, []) | records])
  end

  defp decode_file_records(_groups, _data, _records), do: {:error, :malformed_response}

  defp device_id_category_code(:basic), do: {:ok, 0x01}
  defp device_id_category_code(:regular), do: {:ok, 0x02}
  defp device_id_category_code(:extended), do: {:ok, 0x03}
  defp device_id_category_code(:individual), do: {:ok, 0x04}
  defp device_id_category_code(_category), do: {:error, :invalid_device_id_category}

  defp decode_device_id_objects(<<>>, 0, objects), do: {:ok, reverse(objects, [])}

  defp decode_device_id_objects(
         <<object_id, size, value::binary-size(size), rest::binary>>,
         count,
         objects
       )
       when count > 0 do
    decode_device_id_objects(rest, count - 1, [{object_id, value} | objects])
  end

  defp decode_device_id_objects(_data, _count, _objects), do: :error

  defp all_booleans?([]), do: true
  defp all_booleans?([value | rest]) when is_boolean(value), do: all_booleans?(rest)
  defp all_booleans?(_values), do: false

  defp all_words?([]), do: true

  defp all_words?([value | rest])
       when is_integer(value) and value >= 0 and value <= 0xFFFF,
       do: all_words?(rest)

  defp all_words?(_values), do: false

  defp all_bytes?([]), do: true

  defp all_bytes?([value | rest])
       when is_integer(value) and value >= 0 and value <= 0xFF,
       do: all_bytes?(rest)

  defp all_bytes?(_values), do: false

  defp encode_words([], encoded), do: encoded

  defp encode_words([word | rest], encoded) do
    encode_words(rest, <<encoded::binary, word::16>>)
  end

  defp decode_words(<<>>, words), do: reverse(words, [])
  defp decode_words(<<word::16, rest::binary>>, words), do: decode_words(rest, [word | words])

  defp decode_bytes(<<>>, bytes), do: reverse(bytes, [])
  defp decode_bytes(<<byte, rest::binary>>, bytes), do: decode_bytes(rest, [byte | bytes])

  defp encode_bytes([], encoded), do: encoded
  defp encode_bytes([byte | rest], encoded), do: encode_bytes(rest, <<encoded::binary, byte>>)

  defp pack_bits(bits), do: pack_bits(bits, <<>>)
  defp pack_bits([], packed), do: packed

  defp pack_bits(bits, packed) do
    {byte, rest} = pack_byte(bits, 0, 0)
    pack_bits(rest, <<packed::binary, byte>>)
  end

  defp pack_byte(rest, bit, byte) when bit == 8 or rest == [], do: {byte, rest}

  defp pack_byte([value | rest], bit, byte) do
    next = if value, do: bor(byte, 1 <<< bit), else: byte
    pack_byte(rest, bit + 1, next)
  end

  defp unpack_bits(_data, 0, bits), do: reverse(bits, [])

  defp unpack_bits(<<byte, rest::binary>>, remaining, bits) do
    take = min(remaining, 8)
    next_bits = unpack_byte(byte, 0, take, bits)
    unpack_bits(rest, remaining - take, next_bits)
  end

  defp unpack_byte(_byte, bit, count, bits) when bit == count, do: bits

  defp unpack_byte(byte, bit, count, bits) do
    unpack_byte(byte, bit + 1, count, [band(byte, 1 <<< bit) != 0 | bits])
  end

  defp reverse([], result), do: result
  defp reverse([head | tail], result), do: reverse(tail, [head | result])

  defp exception(0x01), do: :illegal_function
  defp exception(0x02), do: :illegal_data_address
  defp exception(0x03), do: :illegal_data_value
  defp exception(0x04), do: :server_device_failure
  defp exception(0x05), do: :acknowledge
  defp exception(0x06), do: :server_device_busy
  defp exception(0x08), do: :memory_parity_error
  defp exception(0x0A), do: :gateway_path_unavailable
  defp exception(0x0B), do: :gateway_target_device_failed_to_respond
  defp exception(code), do: code

  defp exception_code(:illegal_function), do: {:ok, 0x01}
  defp exception_code(:illegal_data_address), do: {:ok, 0x02}
  defp exception_code(:illegal_data_value), do: {:ok, 0x03}
  defp exception_code(:server_device_failure), do: {:ok, 0x04}
  defp exception_code(:acknowledge), do: {:ok, 0x05}
  defp exception_code(:server_device_busy), do: {:ok, 0x06}
  defp exception_code(:memory_parity_error), do: {:ok, 0x08}
  defp exception_code(:gateway_path_unavailable), do: {:ok, 0x0A}
  defp exception_code(:gateway_target_device_failed_to_respond), do: {:ok, 0x0B}

  defp exception_code(code) when is_integer(code) and code >= 1 and code <= 0xFF,
    do: {:ok, code}

  defp exception_code(_exception), do: {:error, :invalid_exception}
end
