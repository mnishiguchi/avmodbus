defmodule AVModbus.TCP do
  @moduledoc """
  Modbus TCP の MBAP framing と stream extraction を提供します。

  MBAP header は transaction id、protocol id、後続 byte 数、unit id を保持します。
  Modbus の protocol id は常に `0` です。TCP stream に複数 frame が連結されていても
  `decode/1` は先頭の 1 frame だけを返し、残りを保持します。
  """

  @doc "transaction id、unit id、PDU を Modbus TCP ADU に encode します。"
  @spec encode(0..65_535, 0..255, binary()) :: {:ok, binary()} | {:error, term()}
  def encode(transaction_id, unit_id, pdu)
      when is_integer(transaction_id) and transaction_id >= 0 and transaction_id <= 65_535 and
             is_integer(unit_id) and unit_id >= 0 and unit_id <= 255 and is_binary(pdu) and
             byte_size(pdu) >= 1 and byte_size(pdu) <= 253 do
    {:ok, <<transaction_id::16, 0::16, byte_size(pdu) + 1::16, unit_id, pdu::binary>>}
  end

  def encode(transaction_id, _unit_id, _pdu)
      when not is_integer(transaction_id) or transaction_id < 0 or transaction_id > 65_535,
      do: {:error, :invalid_transaction_id}

  def encode(_transaction_id, unit_id, _pdu)
      when not is_integer(unit_id) or unit_id < 0 or unit_id > 255,
      do: {:error, :invalid_unit_id}

  def encode(_transaction_id, _unit_id, _pdu), do: {:error, :invalid_pdu}

  @doc """
  TCP stream の先頭から 1 frame を decode します。

  - `{:ok, transaction_id, unit_id, pdu, rest}`: 完全な Modbus frame
  - `:more`: header または frame が未完了
  - `{:discard, rest}`: protocol id が 0 ではない完全な frame
  - `{:error, :invalid_length}`: PDU が 1..253 bytes にならない MBAP length

  invalid length の後は stream boundary を確定できないため、caller は connection を
  close してください。
  """
  @spec decode(binary()) ::
          {:ok, 0..65_535, 0..255, binary(), binary()}
          | {:discard, binary()}
          | :more
          | {:error, :invalid_length | :invalid_frame}
  def decode(buffer) when is_binary(buffer), do: decode_binary(buffer)
  def decode(_buffer), do: {:error, :invalid_frame}

  defp decode_binary(<<transaction_id::16, protocol_id::16, length::16, rest::binary>>)
       when length >= 2 and length <= 254 do
    case rest do
      <<unit_id, pdu::binary-size(length - 1), tail::binary>> when protocol_id == 0 ->
        {:ok, transaction_id, unit_id, pdu, tail}

      <<_frame::binary-size(length), tail::binary>> ->
        {:discard, tail}

      _partial ->
        :more
    end
  end

  defp decode_binary(<<_transaction_id::16, _protocol_id::16, _length::16, _rest::binary>>),
    do: {:error, :invalid_length}

  defp decode_binary(_partial), do: :more
end
