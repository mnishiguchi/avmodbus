defmodule AVModbus.Serial.Transport do
  @moduledoc """
  Modbus serial transport adapter の contract です。

  `open/1` は instance ごとの設定を keyword list で受け取ります。`read/2` は timeout を
  millisecond で受け取り、`write/2` は
  response の受信へ安全に移れる時点で返す必要があります。manual DE / RE を使う RS485
  adapter では、送信完了待ちと direction の切り替えも `write/2` の責務です。
  """

  @type handle :: term()
  @type options :: keyword()

  @callback open(options()) :: {:ok, handle()} | {:error, term()}
  @callback read(handle(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  @callback write(handle(), iodata()) :: :ok | {:error, term()}
  @callback close(handle()) :: :ok | {:error, term()}
end
