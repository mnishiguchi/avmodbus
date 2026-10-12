# Getting Started

このガイドでは、AVModbus を project に追加し、AtomVM の UART から Modbus RTU request を送るまでを説明します。
Modbus の用語が初めての場合は、先に [Modbus の基礎](MODBUS_BASICS.md) を参照してください。

実際に 2 台の XIAO ESP32-C5 を配線して動かす場合は、完成済みの sample application を使う
[実機チュートリアル](../examples/hello_atomvm_modbus/README.md) が最短です。

## 1. 必要なもの

ソフトウェア:

- Erlang / OTP と Elixir（この repository の `.tool-versions` を推奨）
- `mise`
- AtomVM `release-0.7` 対応 firmware

Modbus RTU を実機で動かす場合:

- AtomVM が動く ESP32 board
- その board の logic voltage に対応した RS485 transceiver
- 接続先の Modbus RTU Server、または Server として動かす 2 台目の board
- A / B / GND を接続する wire

> RS485 transceiver の電源電圧と logic voltage を必ず確認してください。
> 電源を入れたまま配線を変更しないでください。

## 2. AVModbus を project に追加する

AVModbus はまだ Hex package として公開していません。local checkout を path dependency として指定します。

```elixir
defp deps do
  [
    {:avmodbus, path: "../avmodbus"},
    {:exatomvm, github: "atomvm/exatomvm", runtime: false},
    {:atomvm, "~> 0.7.0-beta.0", runtime: false}
  ]
end
```

path は自分の directory 構成に合わせて変更してください。その後、dependency を取得します。

```sh
mix deps.get
```

この repository 内の sample を使う場合、上の設定はすでに
`examples/hello_atomvm_modbus/mix.exs` に含まれています。

## 3. UART を設定する

AVModbus の UART 設定は firmware build 時の application configuration から読みます。
次は XIAO ESP32-C5 で UART1、D4 / GPIO23、D5 / GPIO24、9,600 baud、8N1 を使う例です。

```elixir
import Config

config :avmodbus,
  uart_peripheral: "UART1",
  uart_speed: 9_600,
  uart_tx_pin: 23,
  uart_rx_pin: 24,
  uart_data_bits: 8,
  uart_parity: :none,
  uart_stop_bits: 1
```

pin 番号や UART peripheral は board ごとに異なります。
AtomVM console と同じ UART を使うと、log と Modbus data が衝突するため、別の UART を選びます。

## 4. UART を開く

通常は `AVModbus.Client.start_link/1` が UART を開き、切断時の再接続も管理します。
`serial:` を省略すると上の application configuration を使います。複数の UART / RS485 bus を
使い分ける場合は、instance ごとに上書きできます。

```elixir
{:ok, client} =
  AVModbus.Client.start_link(
    transport: :rtu,
    serial: [
      peripheral: "UART1",
      speed: 9_600,
      tx: 23,
      rx: 24,
      data_bits: 8,
      parity: :none,
      stop_bits: 1
    ],
    timeout: 1_000
  )
```

`gap:` / `silence:` を省略した RTU Client / Server は、この `serial:` の `speed` から frame gap と
unknown-length frame の受信待ち時間を計算します。application configuration の値は下限として使います。

application 側で UART handle を管理する場合だけ、明示的に開いて渡します。

```elixir
{:ok, uart} = AVModbus.UART.open(speed: 9_600, tx: 23, rx: 24)
{:ok, client} = AVModbus.Client.start_link(uart, transport: :rtu, timeout: 1_000)
```

最初は自動で開く一つ目の方法を推奨します。

## 5. Holding Register を読む

Unit ID `1` の address `0` から Holding Register を 2 個読みます。

```elixir
case AVModbus.Client.read_holding_registers(client, 1, 0, 2) do
  {:ok, registers} ->
    IO.inspect(registers, label: "Holding Registers")

  {:error, reason} ->
    IO.puts("Modbus request failed: #{inspect(reason)}")
end
```

成功例:

```text
Holding Registers: [123, 456]
```

引数の意味:

```text
read_holding_registers(client, 1, 0, 2)
                               |  |  |
                               |  |  +-- 読む個数
                               |  +----- 先頭 address
                               +-------- Unit ID
```

## 6. Register を書く

Unit ID `1` の Holding Register address `10` に `42` を書きます。

```elixir
:ok = AVModbus.Client.write_single_register(client, 1, 10, 42)
```

書き込み request を自動 retry すると、機器が同じ操作を複数回実行する危険があります。
AVModbus は読み取りにだけ明示的な retry を許可します。最初は retry を指定せず動作を確認してください。

## 7. Client を終了する

```elixir
:ok = AVModbus.Client.stop(client)
```

supervision tree から起動する方法や非同期 request は [開発者ガイド](DEVELOPMENT.md) を参照してください。

## 8. Modbus TCP を試す

Modbus TCP では UART 設定は使いません。接続先 host と port を指定します。

```elixir
{:ok, client} =
  AVModbus.Client.start_link(
    transport: :tcp,
    host: "192.168.1.20",
    port: 502,
    timeout: 1_000
  )

AVModbus.Client.read_holding_registers(client, 1, 0, 2)
```

## うまくいかないとき

### `{:error, :uart_pins_not_configured}`

`uart_tx_pin` と `uart_rx_pin` が application configuration にありません。
pin 番号を設定し、firmware を clean build してください。

### `{:error, :timeout}`

次を順番に確認します。

1. Client と Server の baud rate、data bits、parity、stop bits が同じか
2. request で指定する Unit ID が Server の Unit ID と一致しているか
3. A / B / GND が正しく接続されているか
4. address が機器の仕様書と一致しているか
5. address の表記が `0` 始まりか `1` 始まりか
6. RS485 transceiver が board の logic voltage に対応しているか

### CRC error になる

- baud rate、parity、stop bits を再確認する
- GND を共通にする
- wire を短くして試す
- 長い bus では両端の termination と bias を機器の仕様に従って確認する

### AtomVM console が読めない

Modbus 用 UART と console 用 UART が重なっていないか確認します。
XIAO ESP32-C5 sample は console に UART0、Modbus に UART1 を使います。

### A / B を接続しても応答しない

メーカーにより A / B の表記が逆の場合があります。電源を切り、両機器の datasheet を確認してください。
最初から電源 wire や UART TX / RX を入れ替えないでください。

## 次に読む

- [XIAO ESP32-C5 実機チュートリアル](../examples/hello_atomvm_modbus/README.md)
- [開発者ガイド](DEVELOPMENT.md)
- [アーキテクチャ](ARCHITECTURE.md)
