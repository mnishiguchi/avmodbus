defmodule AVModbus do
  @moduledoc """
  AtomVM 向けの Modbus ライブラリです。

  protocol の encode / decode を AtomVM `:uart` adapter から分離しているため、
  通常の BEAM runtime 上でもテストできます。RTU / ASCII client / server、
  PDU codec、framing、transport-independent な server handler boundary、
  sparse in-memory data model を提供します。

  client と server handler は同じ result contract を共有します。device が Modbus
  exception を返した場合は `{:error, {:exception, reason}}` です。
  """

  @type unit_id :: 0..255
  @type address :: 0..65_535
  @type word :: 0..65_535
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

  @type error ::
          {:exception, exception()}
          | :timeout
          | :closed
          | :queue_full
          | {:invalid_response, binary()}

  @type result :: :ok | {:ok, term()} | {:error, error()}

  @exceptions %{
    0x01 => :illegal_function,
    0x02 => :illegal_data_address,
    0x03 => :illegal_data_value,
    0x04 => :server_device_failure,
    0x05 => :acknowledge,
    0x06 => :server_device_busy,
    0x08 => :memory_parity_error,
    0x0A => :gateway_path_unavailable,
    0x0B => :gateway_target_device_failed_to_respond
  }

  @doc "Modbus exception code を既知の名前へ変換し、未知の code はそのまま返します。"
  @spec exception_name(byte()) :: exception()
  def exception_name(code) when is_integer(code) and code >= 0 and code <= 0xFF,
    do: Map.get(@exceptions, code, code)

  @doc "Modbus exception 名または code を wire code へ変換します。"
  @spec exception_code(exception()) :: byte()
  def exception_code(code) when is_integer(code) and code >= 1 and code <= 0xFF, do: code

  def exception_code(name) when is_atom(name) do
    case exception_code_by_name(Map.to_list(@exceptions), name) do
      {:ok, code} -> code
      :error -> raise ArgumentError, "not a Modbus exception: #{inspect(name)}"
    end
  end

  def exception_code(exception),
    do: raise(ArgumentError, "not a Modbus exception: #{inspect(exception)}")

  defp exception_code_by_name([{code, name} | _rest], name), do: {:ok, code}

  defp exception_code_by_name([_entry | rest], name),
    do: exception_code_by_name(rest, name)

  defp exception_code_by_name([], _name), do: :error
end
