# hello_atomvm_modbus

`avmodbus` を AtomVM / ESP32 / RS485 で動かす最小サンプルです。

Modbus protocol 実装は repository root の `avmodbus` library にあり、この example は firmware tooling、UART / board 設定、application entrypoint だけを担当します。

## 検証環境

- Seeed Studio XIAO ESP32-C5
- AtomVM `v0.7.0-beta.0`
- Erlang/OTP `28.5.0.7`
- Elixir `1.19.6-otp-28`
- AtomVM console: UART0 (D6 / GPIO11 TX, D7 / GPIO12 RX)
- Modbus: UART1
- Modbus TX: D4 / GPIO23
- Modbus RX: D5 / GPIO24
- 3.3 V logic 対応の自動方向制御 TTL <-> RS485 transceiver

## 配線

```text
XIAO ESP32-C5          TTL <-> RS485
---------------        -------------
3V3              --->  VCC
GND              --->  GND
D4 / GPIO23 TX   --->  TXD
D5 / GPIO24 RX   <---  RXD
                       A -------- RS485 A
                       B -------- RS485 B
```

この配線は検証に使用した HW-519 (MAX485 + CD4069) module のものです。この module の
`TXD` / `RXD` 表示は MCU 側 UART と同名で接続します。transceiver によって pin 名の基準が
異なるため、別製品では回路図または datasheet を確認してください。

各 HW-519 は接続先 XIAO の `3V3` から個別に給電します。2 台の XIAO 間では `GND`、`A`、`B` のみを
接続し、別々の regulator 出力である `3V3` 同士は接続しません。短い bench 配線での検証時は
termination resistor を使用していません。

### UART1 を使用する理由

XIAO ESP32-C5 の公式 pinout では D6 / GPIO11 が TX、D7 / GPIO12 が RX と表示されています。
これらは ESP32-C5 の UART0 の既定 pin で、AtomVM firmware では console に使用されます。

そのため、この example では AtomVM console と Modbus RTU / ASCII の通信が競合しないように、
Modbus 用には別の UART1 を使用します。UART1 の TX / RX は ESP32-C5 の GPIO matrix を使って、
D4 / GPIO23 (TX) と D5 / GPIO24 (RX) に割り当てます。

```text
D6 / GPIO11 ---- UART0 TX ---- AtomVM console
D7 / GPIO12 ---- UART0 RX ---- AtomVM console
                                keep free for console

D4 / GPIO23 ---- UART1 TX ---> HW-519 TXD
D5 / GPIO24 ---- UART1 RX <--- HW-519 RXD
                                AVModbus
```

D4 / D5 は XIAO pinout 上では I2C 用の表示ですが、UART1 専用 pin という意味ではなく、
GPIO matrix によって UART1 の信号を割り当てています。

この構成により、USB 経由の AtomVM console を使いながら、同時に UART1 で RS485 / Modbus 通信を確認できます。

## セットアップ

```sh
cd examples/hello_atomvm_modbus
mise install
mix deps.get
mix atomvm.esp32.install --version v0.7.0-beta.0
mix atomvm.esp32.flash --port /dev/ttyACM0
mix atomvm.esp32.monitor --port /dev/ttyACM0
```

既定では RTU client として起動し、Holding Register を定期的に読みます。

## サーバーモード

```sh
mix clean
MODBUS_ROLE=server mix atomvm.packbeam
MODBUS_ROLE=server mix atomvm.esp32.flash --port /dev/ttyACM0
MODBUS_ROLE=server mix atomvm.esp32.monitor --port /dev/ttyACM0
```

server mode では `AVModbus.Memory` を data model とする in-memory server を起動します。

## RS485 baud-rate 実機検証

2 台の XIAO ESP32-C5 と 2 台の HW-519 を使い、8N1、unit ID 1、function `0x03`、holding register
address 0 / quantity 1、5 秒間隔の条件で次の baud rate を確認しています。client console で
少なくとも 3 回連続して `modbus: registers [0]` を受信することを合格条件としました。

| Baud rate | 結果 |
| ---: | --- |
| 9,600 | pass |
| 19,200 | pass |
| 38,400 | pass |
| 115,200 | pass |

baud rate は compile-time configuration のため、server と client をそれぞれ clean build して flash します。
次は 19,200 baud の例です。

```sh
mix clean
MODBUS_ROLE=server ATOMVM_UART_SPEED=19200 \
mix atomvm.esp32.flash --port /dev/ttyACM_SERVER

mix clean
ATOMVM_UART_SPEED=19200 \
mix atomvm.esp32.flash --port /dev/ttyACM_CLIENT

mix atomvm.esp32.monitor --port /dev/ttyACM_CLIENT
```

`/dev/ttyACM*` の番号は再接続時に変わることがあるため、flash 前に USB serial number で board の
role を確認します。この検証は request / response の成立を確認するもので、echo、turnaround、frame gap の
個別計測を完了したものではありません。

## RS485 cable disconnect / reconnect 実機検証

9,600 baud で client が 5 秒間隔の polling を継続している間に、2 台の HW-519 間の `A` conductor を
実際に切断しました。client console で `modbus: request failed :timeout` を確認してから同じ conductor を
再接続し、board、application、managed client のいずれも再起動せず、4 回連続して
`modbus: registers [0]` に復帰することを確認しています。

この試験は RS485 line loss に対する request-level recovery の確認です。UART peripheral 自体は open のまま
なので、UART driver が `:closed` を返した場合の managed reopen / backoff の実機確認とは区別します。

## Modbus ASCII

client / server とも `MODBUS_MODE=ascii` を指定します。一般的な 7E1 設定の例:

```sh
MODBUS_MODE=ascii \
ATOMVM_UART_DATA_BITS=7 \
ATOMVM_UART_PARITY=even \
mix atomvm.packbeam
```

## Modbus TCP

TCP server を起動する場合は `MODBUS_MODE=tcp MODBUS_ROLE=server` を指定します。実際に LAN から接続するには application 側で AtomVM network interface も設定してください。

```sh
MODBUS_ROLE=server MODBUS_MODE=tcp MODBUS_TCP_PORT=502 mix atomvm.packbeam
```

TCP client では `MODBUS_TCP_HOST` と `MODBUS_TCP_PORT` も指定します。

## Artifact size budget

production artifact を build して size regression budget を確認します。

```sh
MIX_ENV=prod mix atomvm.size
```

baseline と budget の更新方針は [`../../docs/ARTIFACT_SIZE.md`](../../docs/ARTIFACT_SIZE.md) を参照してください。

## 設定

| 環境変数 | 既定値 | 説明 |
| --- | ---: | --- |
| `MODBUS_ROLE` | `client` | `client` / `server` |
| `MODBUS_MODE` | `rtu` | `rtu` / `ascii` / `tcp` |
| `MODBUS_TCP_HOST` | `127.0.0.1` | TCP server host |
| `MODBUS_TCP_PORT` | `502` | TCP listen / destination port |
| `MODBUS_UNIT_ID` | `1` | unit id |
| `MODBUS_START_ADDRESS` | `0` | client が読む Holding Register の開始 address |
| `MODBUS_QUANTITY` | `1` | client が読む register 数 |
| `MODBUS_RESPONSE_TIMEOUT_MS` | `1000` | client startup の default response timeout |
| `MODBUS_REQUEST_INTERVAL_MS` | `5000` | polling interval |
| `MODBUS_HEALTH_INTERVAL_MS` | `0` | device health snapshot の間隔。`0` 以下で無効 |
| `MODBUS_MEASURE_MEMORY` | `false` | startup 前後の ESP32 heap と client / server process memory を出力するか |
| `MODBUS_RESOURCE_PROBE` | `false` | TCP loopback の bounded resource recovery probe を起動するか |
| `MODBUS_RESOURCE_PROBE_CYCLES` | `3` | resource probe の反復回数 |
| `MODBUS_RESOURCE_PROBE_CONNECTIONS` | `4` | cycle ごとの loopback client / server connection 数 |
| `ATOMVM_UART_PERIPHERAL` | `UART1` | UART peripheral |
| `ATOMVM_UART_SPEED` | `9600` | baud rate |
| `ATOMVM_UART_TX_PIN` | `23` | TX GPIO (XIAO ESP32-C5 D4) |
| `ATOMVM_UART_RX_PIN` | `24` | RX GPIO (XIAO ESP32-C5 D5) |
| `ATOMVM_UART_DATA_BITS` | `8` | data bits |
| `ATOMVM_UART_PARITY` | `none` | `none` / `even` / `odd` |
| `ATOMVM_UART_STOP_BITS` | `1` | stop bits |
| `MODBUS_ECHO` | `false` | adapter echo を除去するか |
| `MODBUS_SILENCE_MS` | `20` | unknown-length frame の silent interval |
| `MODBUS_BROADCAST_TURNAROUND_MS` | `100` | broadcast write 後の待ち時間 |
| `MODBUS_HANDLER_TIMEOUT_MS` | `10000` | server handler timeout |
| `MODBUS_RECONNECT_MIN_MS` | `100` | UART reopen の最初の delay |
| `MODBUS_RECONNECT_MAX_MS` | `5000` | UART reopen delay の上限 |

これらは compile-time configuration として使われるため、設定を変えた場合は必要に応じて `mix clean` してから build してください。

## Memory footprint measurement

AtomVM / ESP32 上で role startup 前後の heap と process memory を計測します。

```sh
MODBUS_MEASURE_MEMORY=true MIX_ENV=prod mix atomvm.packbeam
MODBUS_MEASURE_MEMORY=true MIX_ENV=prod mix atomvm.esp32.flash --port /dev/ttyACM0
mix atomvm.esp32.monitor --port /dev/ttyACM0
```

server を計測する場合は clean 後、build と flash の両方で `MODBUS_ROLE=server` も指定します。出力される
`modbus_memory` line は free heap delta、largest / minimum free heap、binary memory、process count、
各 managed process の推定 byte 数を含みます。

## Device soak telemetry

長時間の実機検証では `MODBUS_HEALTH_INTERVAL_MS` を正の値にして build / flash します。
client / server の connection state、uptime、ESP32 free heap、minimum free heap、binary memory、
process count、managed process ごとの memory と mailbox length を `modbus_health` line として定期出力します。

```sh
MIX_ENV=prod mix clean

MODBUS_ROLE=server \
MODBUS_HEALTH_INTERVAL_MS=60000 \
MIX_ENV=prod \
mix atomvm.packbeam

MODBUS_ROLE=server \
MODBUS_HEALTH_INTERVAL_MS=60000 \
MIX_ENV=prod \
mix atomvm.esp32.flash --port /dev/ttyACM0

mix atomvm.esp32.monitor --port /dev/ttyACM0
```

この telemetry は観測機能であり、それ自体を external Modbus peer との interoperability 成功とは扱いません。
実 RS485 traffic を使った計測条件と結果は
[`../../docs/MEMORY_FOOTPRINT.md`](../../docs/MEMORY_FOOTPRINT.md#2026-10-10-real-rs485-baseline)
に記録しています。

## Device resource recovery probe

TCP server の connection cap、client の pending / wait queue、slow handler process を同時に動かし、
`:queue_full`、正常 response、socket / process cleanup、free-heap recovery を loopback 上で反復確認できます。
通常 application には含めない compile-time diagnostic mode です。

```sh
MIX_ENV=prod mix clean

MODBUS_RESOURCE_PROBE=true \
MIX_ENV=prod \
mix atomvm.packbeam

MODBUS_RESOURCE_PROBE=true \
MIX_ENV=prod \
mix atomvm.esp32.flash --port /dev/ttyACM0

mix atomvm.esp32.monitor --port /dev/ttyACM0
```

最初の warm-up で AtomVM / ESP-IDF network stack の one-time allocation を完了してから、各 measured cycle は
`before / peak / after cleanup` の process count、free heap、largest free block を出力します。
全 request result、5 秒以内の process cleanup、steady-state baseline から 32 KiB 以内の free-heap recovery が成功した場合だけ最終的に
`modbus_resource_probe result=ok` を出力します。

AtomVM `0.7.0-beta.0+git.8d3e051` では複数の loopback socket をまとめて閉じた際、ESP32 socket driver が
`event_queue` への enqueue failure を出力する場合があります。これは bounded FreeRTOS queue の platform
warning です。probe の最終結果が `ok` で、各 cycle の process count と free heap が回復していれば、
AVModbus の resource leak を示すものではありません。hard-limit 付近の挙動とは区別してください。

## トラブルシューティング

OTP 28 で firmware download 時に `:ssl.versions/0` の load error が出る場合は、SSL application を起動した `mix run` 経由で image を download できます。

```sh
mix run -e 'Mix.Tasks.Atomvm.Esp32.Install.run(["--version", "v0.7.0-beta.0", "--download-only", "--chip", "esp32c5"])'
mix atomvm.esp32.install --image firmware_images/AtomVM-esp32c5-elixir-v0.7.0-beta.0.img
```
