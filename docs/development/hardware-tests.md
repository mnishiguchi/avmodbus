# 実機での追加検証

このページは、最初の通信確認を終えた開発者向けです。配線・書き込みの基本手順は
[実機チュートリアル](../../examples/hello_atomvm_modbus/README.md) を参照してください。

以下は記録した XIAO ESP32-C5 / HW-519 の検証方法です。別の機器で同じ結果になるとは限りません。


ここから先は、最初の通信確認には不要です。baud rate、障害復旧、memory、長時間運転、resource limit を
再検証するときに使用します。

## RS485 baud rate の実機検証

2 台の XIAO ESP32-C5 と 2 台の HW-519 を使い、8N1、unit ID 1、function `0x03`、holding register
address 0 / quantity 1、5 秒間隔の条件で次の baud rate を確認しています。client console で
少なくとも 3 回連続して `modbus: registers [0]` を受信することを合格条件としました。

| Baud rate | 結果 |
| ---: | --- |
| 9,600 | 成功 |
| 19,200 | 成功 |
| 38,400 | 成功 |
| 115,200 | 成功 |

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

## RS485 cable の切断と再接続

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

## Artifact size の上限

production artifact を build して size regression budget を確認します。

```sh
MIX_ENV=prod mix atomvm.size
```

baseline と budget の更新方針は
[リソース計測](https://github.com/piyopiyoex/avmodbus/blob/main/docs/development/resource-measurements.md#ファームウェアサイズ)
を参照してください。

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
| `MODBUS_RESOURCE_PROBE_CONNECTIONS` | `4` | cycle ごとの loopback client / server connection 数。安全確認済み範囲は `1..4` |
| `MODBUS_WORKFLOW_PROBE` | `false` | real RS485 representative workflow probe を起動するか |
| `MODBUS_WORKFLOW_PROBE_CYCLES` | `3` | workflow probe の反復回数 |
| `MODBUS_WORKFLOW_GAP_MS` | `20` | workflow probe の送信前 gap。`0` は baud rate から算出 |
| `ATOMVM_UART_PERIPHERAL` | `UART1` | UART peripheral |
| `ATOMVM_UART_SPEED` | `9600` | baud rate |
| `ATOMVM_UART_TX_PIN` | `23` | TX GPIO (XIAO ESP32-C5 D4) |
| `ATOMVM_UART_RX_PIN` | `24` | RX GPIO (XIAO ESP32-C5 D5) |
| `ATOMVM_UART_DATA_BITS` | `8` | data bits |
| `ATOMVM_UART_PARITY` | `none` | `none` / `even` / `odd` |
| `ATOMVM_UART_STOP_BITS` | `1` | stop bits |
| `ATOMVM_UART_RX_IDLE_TIMEOUT_MS` | `20` | AtomVM UART の隣接 chunk をまとめる idle timeout |
| `MODBUS_ECHO` | `false` | adapter echo を除去するか |
| `MODBUS_RTU_GAP_MS` | `0` | 通常 RTU client / server の送信前 gap。`0` は baud rate から算出 |
| `MODBUS_SILENCE_MS` | `20` | unknown-length frame の silent interval |
| `MODBUS_BROADCAST_TURNAROUND_MS` | `100` | broadcast write 後の待ち時間 |
| `MODBUS_HANDLER_TIMEOUT_MS` | `10000` | server handler timeout |
| `MODBUS_RECONNECT_MIN_MS` | `100` | UART reopen の最初の delay |
| `MODBUS_RECONNECT_MAX_MS` | `5000` | UART reopen delay の上限 |

これらは compile-time configuration として使われるため、設定を変えた場合は必要に応じて `mix clean` してから build してください。

## Memory 使用量の測定

AtomVM / ESP32 上で role startup 前後の heap と process memory を計測します。

```sh
MODBUS_MEASURE_MEMORY=true MIX_ENV=prod mix atomvm.packbeam
MODBUS_MEASURE_MEMORY=true MIX_ENV=prod mix atomvm.esp32.flash --port /dev/ttyACM0
mix atomvm.esp32.monitor --port /dev/ttyACM0
```

server を計測する場合は clean 後、build と flash の両方で `MODBUS_ROLE=server` も指定します。出力される
`modbus_memory` line は free heap delta、largest / minimum free heap、binary memory、process count、
各 managed process の推定 byte 数を含みます。

## 実機 soak test の状態出力

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
[Memory 使用量の実 RS485 基準値](https://github.com/piyopiyoex/avmodbus/blob/main/docs/development/resource-measurements.md#2026-10-10-実-rs485-基準値)に
記録しています。

## 実機の resource recovery probe

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
`before / connected idle / active snapshot / after cleanup` の process count、free heap、largest free block を出力します。
loopback Client と Server connection の両方を含む deployed probe 全体の値であり、Server connection 単体の
heap cost ではありません。active snapshot は request 投入直後の一点計測で、連続観測した最大値ではありません。
`MODBUS_RESOURCE_PROBE_CONNECTIONS=1..4` を同じ firmware / configuration で比較し、確認済み範囲内の増分を評価できます。
全 request result、5 秒以内の process cleanup、steady-state baseline から 32 KiB 以内の free-heap recovery が成功した場合だけ最終的に
`modbus_resource_probe result=ok` を出力します。

retained probe はこの board / firmware で回復を確認した `1..4` connections だけを受け付けます。
`0` 以下は invalid configuration、`5` 以上は `unsafe_connection_count` として socket を開く前に停止します。
hard-limit 調査では production example の guard を緩めず、symbol 付き runtime と一時 diagnostic build を使用してください。

AtomVM `0.7.0-beta.0+git.8d3e051` では複数の loopback socket をまとめて閉じた際、ESP32 socket driver が
`event_queue` への enqueue failure を出力する場合があります。これは bounded FreeRTOS queue の platform
warning です。probe の最終結果が `ok` で、各 cycle の process count と free heap が回復していれば、
AVModbus の resource leak を示すものではありません。hard-limit 付近の挙動とは区別してください。

## 実 RS485 workflow probe

通常の RTU または ASCII server image を一方の board に flash した後、もう一方に同じ mode の
compile-time workflow probe を flash すると、実 RS485 bus 上で registers、coils、mask write、
read/write multiple、file record、FIFO、diagnostics、device identification、broadcast と exception
response を連続確認できます。

```sh
# Server board
MIX_ENV=prod mix clean
MODBUS_ROLE=server MIX_ENV=prod mix atomvm.packbeam
MODBUS_ROLE=server MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM_SERVER

# Client/probe board
MIX_ENV=prod mix clean
MODBUS_WORKFLOW_PROBE=true MIX_ENV=prod mix atomvm.packbeam
MODBUS_WORKFLOW_PROBE=true MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM_CLIENT
mix atomvm.esp32.monitor --port /dev/ttyACM_CLIENT
```

Modbus ASCII 7E1 では、Server と Client/probe の build / flash command すべてに次の環境変数を追加します。

```sh
MODBUS_MODE=ascii ATOMVM_UART_DATA_BITS=7 ATOMVM_UART_PARITY=even
```

XIAO ESP32-C5 と HW-519 の組み合わせでは、RTU 8N1 に加えて ASCII 7E1 でもこの workflow を実機確認済みです。

probe は最初に write-single response が request と同一 frame になる性質を使い、`echo: true` で
local adapter echo の有無を分類します。その後は `echo: false` で 20-step workflow を 3 cycle
実行します。transport wrapper が response read と次の UART write の時刻を記録し、configured serial gap
以上であることを確認します。broadcast write の所要時間も configured turnaround 以上で、その直後の
read が更新値を返す場合だけ成功です。最後の `modbus_workflow result=ok` line に request 数と timing
summary を出力します。

ASCII 7E1、9,600 baud、20 ms gap では 3 cycle / 60 request を 2 回連続で完走し、最小の
response-to-next-write は 36 ms、100 ms broadcast turnaround の実測値は 130 ms でした。

この計測は AtomVM UART API 境界の millisecond timestamp であり、RS485 waveform の oscilloscope / logic
analyzer 計測を置き換えるものではありません。`MODBUS_RESOURCE_PROBE` と同時には有効にしないでください。
`MODBUS_WORKFLOW_GAP_MS=0` で protocol から算出した gap を使い、正の値で hardware margin を比較できます。

検証した XIAO ESP32-C5 / HW-519 pair の 9,600 baud run では local echo はありませんでした。protocol から
算出した 5 ms では第 2 cycle、10 ms では第 3 cycle に request timeout が再現し、20 ms では 3 cycle / 60
request がすべて成功しました。20 ms run の UART API 境界で観測した最小 response-to-next-write interval は
37 ms、100 ms に設定した broadcast turnaround の request elapsed は 130 ms でした。このため workflow
probe の既定値は、この hardware profile で安定した 20 ms としています。

同じ margin を通常 application に適用する場合は、client / server image の build と flash の両方で
`MODBUS_RTU_GAP_MS=20` を指定します。この値は RTU request / response の送信前 delay の下限となり、
unknown-length frame を確定する `MODBUS_SILENCE_MS` には影響しません。個別の injected transport 利用時は
従来どおり managed client / server の `gap:` option で上書きできます。

`ATOMVM_UART_RX_IDLE_TIMEOUT_MS` は、AtomVM UART の read 呼び出し間で byte を失わないために隣接 chunk を
drain する UART 固有の時間です。既定 20 ms はこの ESP32-C5 / AtomVM 0.7 構成で検証済みです。
Modbus の `gap` / `silence` とは別の設定であり、短縮する場合は長い request と fragmented response を含む
workflow probe を再実行してください。

2026-10-13 に RTU 8N1、20 ms transmit gap、3 cycle / 60 request で比較した結果です。所要時間は
Client API の end-to-end 値であり、RX idle timeout だけの microbenchmark ではありません。

| Baud rate | RX idle | 結果 | Request min / avg / max |
| ---: | ---: | --- | ---: |
| 9,600 | 20 ms | 60 / 60 成功 | 136 / 179 / 233 ms |
| 9,600 | 10 ms | 5 request 目で timeout | 途中終了 |
| 115,200 | 20 ms | 60 / 60 成功 | 134 / 144 / 164 ms |

10 ms では長い `write_multiple_registers` request への response が得られませんでした。このため、現在は
低遅延化より frame の完全性を優先して 20 ms を既定値とします。workflow の最終行は `speed`、
`rx_idle_timeout_ms`、request の min / average / max を出力するため、別の board / UART driver でも同じ
判定基準で比較できます。console の記録には `tio --baudrate 115200 /dev/ttyACM_CLIENT` も使用できます。

## Firmware download のトラブルシューティング

OTP 28 で firmware download 時に `:ssl.versions/0` の load error が出る場合は、SSL application を起動した `mix run` 経由で image を download できます。

```sh
mix run -e 'Mix.Tasks.Atomvm.Esp32.Install.run(["--version", "v0.7.0-beta.0", "--download-only", "--chip", "esp32c5"])'
mix atomvm.esp32.install --image firmware_images/AtomVM-esp32c5-elixir-v0.7.0-beta.0.img
```
