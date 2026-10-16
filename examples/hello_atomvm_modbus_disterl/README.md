# Modbus RTU 上で distributed Erlang を試す（実験）

2 台の AtomVM と 2-wire RS485 を使う、独立した実験用 Mix project です。
既存の AVModbus core には変更を加えず、local path dependency と user-defined
Function Code `100` (`0x64`) だけを利用します。

2026-10-15 に 2 台の Seeed Studio XIAO ESP32-C5 で次を確認しました。

- Phase 1: 3 個ずつの logical message を双方向へ順序どおり配達し、全 ACK を確認
- response 消失を模擬した duplicate suppression の host test
- Server の起動を 60 秒遅らせ、Client の 4 回の timeout 後に実機上で自動復旧
- Phase 2: `net_kernel` / `dist_util` / `serial_dist` の genuine distribution handshake
- remote process への ping / pong を 3 回実行（RTT: 2671 ms、802 ms、802 ms）

アーキテクチャ、制限、設計判断の一覧は [docs/README.md](docs/README.md)、詳細な実機ログと観察結果は
[2026-10-15-hardware-verification.md](docs/worklog/2026-10-15-hardware-verification.md) にあります。

## Hardware と配線

- Seeed Studio XIAO ESP32-C5 × 2
- HW-519 TTL-to-RS485 transceiver × 2
- AtomVM `v0.7.0-beta.0`
- 9,600 baud、8N1、Unit ID `1`

両方の XIAO を次のように配線します。

| XIAO ESP32-C5 | HW-519 | 用途 |
| --- | --- | --- |
| `3V3` | `VCC` | transceiver 電源 |
| `GND` | `GND` | 共通 GND |
| `D4 / GPIO23` | `TXD` | UART1 TX |
| `D5 / GPIO24` | `RXD` | UART1 RX |

transceiver 間は `A+ ↔ A+`、`B- ↔ B-`、`GND ↔ GND` とします。2 台の
XIAO の `3V3` 同士は接続しません。UART0 (GPIO11 / GPIO12) は AtomVM console
が使うため、Modbus は UART1 を使います。詳しい注意事項は
[既存の RTU example](../hello_atomvm_modbus/README.md#2-配線する) を参照してください。

## 準備と host test

repository root から:

```sh
cd examples/hello_atomvm_modbus_disterl
mise install
mix deps.get
mix atomvm.esp32.install --version v0.7.0-beta.0

mix format --check-formatted
mix test
```

host test は packet validation、FIFO ordering、ACK、lost-response retry、duplicate
suppression、CRC error と連続 timeout 後の復旧、custom PDU / RTU frame の end-to-end encode/decode を確認します。

## Phase 1: logical transport probe

以下では `/dev/ttyACM0` を Server、`/dev/ttyACM1` を Client とします。同じ
project を異なる compile-time role で build するため、role を変える前に必ず
`mix clean` を実行します。

Server:

```sh
MODBUS_ROLE=server MIX_ENV=prod mix clean
MODBUS_ROLE=server MIX_ENV=prod mix atomvm.packbeam
MODBUS_ROLE=server MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM0
```

Client:

```sh
MIX_ENV=prod mix clean
MIX_ENV=prod mix atomvm.packbeam
MIX_ENV=prod mix atomvm.esp32.flash --port /dev/ttyACM1
```

両方を monitor すると、成功時には次が表示されます。

```text
# Server
disterl_probe: server received "client message 1"
disterl_probe: server received "client message 2"
disterl_probe: server received "client message 3"

# Client
disterl_probe: client received "server message 1"
disterl_probe: client received "server message 2"
disterl_probe: client received "server message 3"
disterl_probe: complete (3 ordered messages each way; all acknowledged)
```

timeout recovery を再現するには Server build に起動 delay を入れます。

```sh
MODBUS_ROLE=server MODBUS_START_DELAY_MS=60000 MIX_ENV=prod mix clean
MODBUS_ROLE=server MODBUS_START_DELAY_MS=60000 MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM0
```

Server が UART を開く前は Client が `exchange failed :timeout; retrying` を出し、
Server 起動後は同じ sequence を再送して上の complete 状態へ進みます。

## Phase 2: genuine distributed Erlang

Server (`b@modbus.local`):

```sh
MODBUS_EXPERIMENT=disterl MODBUS_ROLE=server MIX_ENV=prod mix clean
MODBUS_EXPERIMENT=disterl MODBUS_ROLE=server MIX_ENV=prod \
  mix atomvm.packbeam
MODBUS_EXPERIMENT=disterl MODBUS_ROLE=server MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM0
```

Client (`a@modbus.local`):

```sh
MODBUS_EXPERIMENT=disterl MIX_ENV=prod mix clean
MODBUS_EXPERIMENT=disterl MIX_ENV=prod mix atomvm.packbeam
MODBUS_EXPERIMENT=disterl MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM1
```

両方をほぼ同時に reset / power-cycle して monitor します。transport version 2 は
32-bit session ID を wire format に持ち、片側の reset 後に古い ACK を無視して
receive sequence を再同期します。

```sh
MIX_ENV=prod mix atomvm.esp32.monitor --port /dev/ttyACM0
MIX_ENV=prod mix atomvm.esp32.monitor --port /dev/ttyACM1
```

成功時の Client log:

```text
modbus_disterl: sending ping 1 to :b@modbus.local payload_bytes=0
modbus_disterl: received pong 1 from :b@modbus.local rtt_ms=... payload_bytes=0
modbus_disterl: received pong 2 from :b@modbus.local rtt_ms=... payload_bytes=0
modbus_disterl: received pong 3 from :b@modbus.local rtt_ms=... payload_bytes=0
modbus_disterl: complete 3 remote ping/pong messages
```

Server には `received ping N from :a@modbus.local` が表示されます。この remote
message は registered process `:modbus_disterl_demo` 宛に Erlang distribution を
通して送信されます。

## Build-time configuration

| environment variable | default | 意味 |
| --- | --- | --- |
| `MODBUS_EXPERIMENT` | `transport` | `disterl` で Phase 2 |
| `MODBUS_ROLE` | `client` | `client` または `server` |
| `ATOMVM_UART_PERIPHERAL` | `UART1` | UART peripheral |
| `ATOMVM_UART_SPEED` | `9600` | baud rate |
| `ATOMVM_UART_TX_PIN` | `23` | TX GPIO |
| `ATOMVM_UART_RX_PIN` | `24` | RX GPIO |
| `MODBUS_UNIT_ID` | `1` | Server unit ID |
| `MODBUS_RESPONSE_TIMEOUT_MS` | `1000` / `500` | Phase 1 / Phase 2 transaction timeout |
| `MODBUS_POLL_INTERVAL_MS` | `1000` / `20` | Phase 1 / Phase 2 polling interval |
| `MODBUS_TRACE_TRANSACTIONS` | unset | `1` / `true` で non-idle transaction と全 failure の size、latency、累積成否を記録 |
| `MODBUS_START_DELAY_MS` | `0` | recovery test 用の起動 delay |
| `ATOMVM_NODE_ALIAS` | role から `a` / `b` | local node alias |
| `ATOMVM_PEER_ALIAS` | role から `b` / `a` | peer node alias |
| `ATOMVM_COOKIE` | `AtomVM` | distribution cookie |
| `DISTERL_PING_COUNT` | `3` | remote ping 回数 |
| `DISTERL_PING_DELAY_MS` | `2000` | boot 後の最初の ping delay |
| `DISTERL_PONG_TIMEOUT_MS` | `15000` | pong timeout |
| `DISTERL_PAYLOAD_BYTES` | `0` | ping/pong で検証する deterministic payload size |

これらは `Application.compile_env/3` で application に埋め込まれます。値を変更する
ときは `mix clean` して、同じ environment で pack / flash してください。

232-byte の Modbus chunk 上限を超える genuine distribution message を検証する場合は、両 node を同じ
`DISTERL_PAYLOAD_BYTES` で build します。低 baud rate では `DISTERL_PONG_TIMEOUT_MS` も十分に延ばしてください。
現在確認されている multi-chunk 実機試験の制約は
[large distribution payload の作業記録](docs/worklog/2026-10-16-large-distribution-payload.md) を参照してください。

## References

- [AtomVM](https://github.com/atomvm/AtomVM)
- [AtomVM distributed Erlang documentation](https://doc.atomvm.org/release-0.7/distributed-erlang.html)
- [direct UART serial distribution experiment](https://github.com/mnishiguchi/hello_atomvm_serial_disterl)
- [AVModbus](https://github.com/mnishiguchi/avmodbus)
