defmodule AVModbus.RTU do
  @moduledoc """
  Modbus RTU framing、CRC validation、stream extraction を提供します。

  known function は response length から frame boundary を決め、CRC で確認します。
  leading noise や invalid byte は skip して次の valid frame へ再同期できます。
  """

  alias AVModbus.{CRC16, PDU}

  @max_frame_size 256

  @spec encode(0..247, binary()) :: {:ok, binary()} | {:error, term()}
  def encode(unit_id, pdu)
      when is_integer(unit_id) and unit_id >= 0 and unit_id <= 247 and is_binary(pdu) and
             byte_size(pdu) >= 1 and byte_size(pdu) <= 253 do
    {:ok, CRC16.append(<<unit_id, pdu::binary>>)}
  end

  def encode(unit_id, _pdu) when not is_integer(unit_id) or unit_id < 0 or unit_id > 247,
    do: {:error, :invalid_unit_id}

  def encode(_unit_id, _pdu), do: {:error, :invalid_pdu}

  @spec decode(binary()) :: {:ok, 0..247, binary()} | {:error, term()}
  def decode(frame)
      when is_binary(frame) and byte_size(frame) >= 4 and byte_size(frame) <= @max_frame_size do
    if CRC16.valid?(frame) do
      pdu_size = byte_size(frame) - 3
      <<unit_id, pdu::binary-size(pdu_size), _crc::binary-size(2)>> = frame
      {:ok, unit_id, pdu}
    else
      {:error, :invalid_crc}
    end
  end

  def decode(frame) when is_binary(frame) and byte_size(frame) > @max_frame_size,
    do: {:error, :frame_too_long}

  def decode(_frame), do: {:error, :frame_too_short}

  @doc """
  byte stream の先頭から response frame を取り出します。

  先頭 byte が期待する response の開始になれない場合は `:skip` を返します。
  caller は 1 byte 捨てて再試行し、後続の valid frame を保持できます。
  """
  @spec split_response(binary(), 1..247, PDU.request()) ::
          {:ok, binary(), binary()} | :more | :unknown | :skip
  def split_response(<<>>, _unit_id, _request), do: :more

  def split_response(<<unit_id, _rest::binary>>, expected_unit_id, _request)
      when unit_id != expected_unit_id,
      do: :skip

  def split_response(<<_unit_id, pdu::binary>> = buffer, _expected_unit_id, request) do
    case PDU.response_length(request, pdu) do
      {:ok, pdu_size} -> extract_known_length(buffer, pdu_size + 3)
      :unknown -> :unknown
      :more -> if byte_size(buffer) < @max_frame_size, do: :more, else: :skip
      :invalid -> :skip
    end
  end

  @doc """
  byte stream の先頭から Modbus request frame を取り出します。

  known request は function-specific な PDU shape から length を求めます。
  undefined function や variable-length request は silent interval で完了するまで `:unknown` を返します。
  """
  @spec split_request(binary()) ::
          {:ok, binary(), binary()} | :more | :unknown | :skip | :overflow
  def split_request(<<>>), do: :more

  def split_request(<<unit_id, _rest::binary>>) when unit_id > 247, do: :skip

  def split_request(<<_unit_id, pdu::binary>> = buffer) do
    case PDU.request_length(pdu) do
      {:ok, pdu_size} -> extract_known_length(buffer, pdu_size + 3)
      :unknown -> if byte_size(buffer) <= @max_frame_size, do: :unknown, else: :overflow
      :more -> if byte_size(buffer) < @max_frame_size, do: :more, else: :overflow
      :invalid -> :skip
    end
  end

  @doc """
  silence-delimited response を検証し、可能な場合は leading noise を skip して再同期します。
  """
  @spec complete_silence_response(binary(), 1..247, PDU.request()) ::
          {:ok, binary()} | {:error, term()}
  def complete_silence_response(buffer, unit_id, request)
      when is_binary(buffer) and is_integer(unit_id) and unit_id >= 1 and unit_id <= 247 do
    complete_silence_response_suffix(buffer, unit_id, request)
  end

  defp complete_silence_response_suffix(buffer, _unit_id, _request) when byte_size(buffer) < 4,
    do: {:error, :frame_too_short}

  defp complete_silence_response_suffix(buffer, unit_id, request) do
    case decode(buffer) do
      {:ok, ^unit_id, <<function, _rest::binary>>} ->
        case PDU.function(request) do
          {:ok, expected} when function == expected or function == expected + 0x80 ->
            {:ok, buffer}

          _other ->
            skip_silence_byte(buffer, unit_id, request)
        end

      _other ->
        skip_silence_byte(buffer, unit_id, request)
    end
  end

  defp skip_silence_byte(<<_byte, rest::binary>>, unit_id, request),
    do: complete_silence_response_suffix(rest, unit_id, request)

  @doc """
  silence-delimited request を検証し、可能な場合は leading noise を skip して再同期します。
  """
  @spec complete_silence_request(binary()) :: {:ok, binary()} | {:error, term()}
  def complete_silence_request(buffer) when is_binary(buffer),
    do: complete_silence_request_suffix(buffer)

  defp complete_silence_request_suffix(buffer) when byte_size(buffer) < 4,
    do: {:error, :frame_too_short}

  defp complete_silence_request_suffix(buffer) do
    case decode(buffer) do
      {:ok, unit_id, <<function, _rest::binary>>} when unit_id <= 247 and function in 1..127 ->
        {:ok, buffer}

      _other ->
        <<_byte, rest::binary>> = buffer
        complete_silence_request_suffix(rest)
    end
  end

  @doc """
  推奨される RTU inter-frame gap を microsecond で返します。

  19,200 baud 以下では 11-bit character の 3.5 倍、より高速では fixed 1.75 ms を使います。
  """
  @spec frame_gap_us(pos_integer()) :: pos_integer()
  def frame_gap_us(speed) when is_integer(speed) and speed > 19_200, do: 1_750

  def frame_gap_us(speed) when is_integer(speed) and speed > 0 do
    div(38_500_000 + speed - 1, speed)
  end

  defp extract_known_length(_buffer, frame_size) when frame_size > @max_frame_size, do: :skip

  defp extract_known_length(buffer, frame_size) when byte_size(buffer) < frame_size, do: :more

  defp extract_known_length(buffer, frame_size) do
    <<frame::binary-size(frame_size), rest::binary>> = buffer

    case decode(frame) do
      {:ok, _unit_id, _pdu} -> {:ok, frame, rest}
      {:error, _reason} -> :skip
    end
  end
end
