defmodule AVModbus.Serial do
  @moduledoc """
  Modbus serial-line implementation で共有する transport-independent helper です。
  """

  @doc """
  `data` の先頭から expected adapter echo と一致する部分を取り除きます。

  `{remaining_echo, data_after_echo}` を返します。echo が複数 UART read に分割されても処理できます。
  受信 data が expected echo と異なった時点で matching を終了し、その data は response input として保持します。
  """
  @spec strip_echo(binary(), binary()) :: {binary(), binary()}
  def strip_echo(<<>>, data) when is_binary(data), do: {<<>>, data}

  def strip_echo(echo, data) when is_binary(echo) and is_binary(data) do
    size = min(byte_size(echo), byte_size(data))
    <<head::binary-size(size), remaining_echo::binary>> = echo

    case data do
      <<^head::binary-size(size), rest::binary>> -> {remaining_echo, rest}
      _other -> {<<>>, data}
    end
  end
end
