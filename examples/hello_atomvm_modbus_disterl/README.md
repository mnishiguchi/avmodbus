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

2026-10-16 の follow-up では、96-byte operating chunk と adaptive response timeout を使い、512-byte payload の
genuine distribution ping/pong を双方向に完了しました（RTT: 7889 ms）。詳細は
[bidirectional multi-chunk round trip](docs/worklog/2026-10-16-bidirectional-multichunk.md) を参照してください。

同じ構成の 30-message soak test では、512-byte payload を 30 往復、223.327 秒にわたって error なしで配送しました。
RTT の min / average / max は 5250 / 5425 / 7477 ms、pong timeout は 0 回でした。詳細は
[application-traffic soak test](docs/worklog/2026-10-16-application-traffic-soak.md) を参照してください。

baud / poll matrix では 9,600–115,200 baud と 20 ms poll の zero-byte ping/pong が成功しました。9,600 baud では
500 ms poll まで成功し、1,000 ms で distribution setup timeout になりました。再現条件と測定値は
[baud-rate / poll-interval matrix](docs/worklog/2026-10-16-baud-poll-matrix.md) にあります。大きな payload を含む検証範囲が
最も広い 9,600 baud / 20 ms を引き続き default とします。

115,200 baud / 20 ms の follow-up では、512-byte payload を 30 往復、99.877 秒にわたって timeout なしで配送し、
4 KiB payload の 1 往復も 22.617 秒で完了しました。また、default の 9,600 baud では同じ 4 KiB payload を
3回連続して往復させ、timeout なしで完了しました（RTT min / average / max: 33.817 / 34.743 / 36.594 秒）。詳細は
[payload traffic verification](docs/worklog/2026-10-16-high-baud-payloads.md) を参照してください。4 KiB の連続試験は
9,600 baud の 1 run に限られるため、default は変更せず、一般的な安定動作としては保証しません。

確立済み connection では、2回目の 4 KiB upload の最初の 96-byte chunk を Server が受信した直後に Server を
reboot しても、Client が session 変更を検出し、1回の pong timeout 後に同じ message を再送して復旧しました。
一方、initial handshake 中に stale session から現在の session へ切り替わった後、connection retry が進まない
起動順序依存も見つかっています。default build は Client のFC-100 adapterを先に開き、Serverから有効なresponseを
受け取ってから同じadapterを`serial_dist`へ渡します。Clientを約70秒先行させた実機runでもping/pong 3 / 3へ進みました。
これは AtomVM の任意のhalf-open connection cleanupを修正するものではありません。
調査、棄却した retry wrapper、2 run の実機結果は
[initial-handshake liveness investigation](docs/worklog/2026-10-16-initial-handshake-liveness.md) に記録しています。

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

両方をreset / power-cycleしてmonitorします。defaultではClientがFC-100 responseを確認するまで`net_kernel`を
開始しないため、Serverが遅れて起動しても7秒のdistribution setup timerを消費しません。transport version 2 は
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
modbus_disterl: complete 3 remote ping/pong messages rtt_min_ms=... rtt_avg_ms=... rtt_max_ms=... timeouts=0 elapsed_ms=...
```

Server には `received ping N from :a@modbus.local` が表示されます。この remote
message は registered process `:modbus_disterl_demo` 宛に Erlang distribution を
通して送信されます。

長時間の application-traffic test では `DISTERL_PING_COUNT` と payload size を増やします。例えば実機で確認した
30-message / 512-byte 構成は次のとおりです。Server と Client の両方を同じ値で clean、pack、flash してください。

```sh
DISTERL_PAYLOAD_BYTES=512 DISTERL_PING_COUNT=30 \
  DISTERL_PONG_TIMEOUT_MS=60000 MODBUS_EXPERIMENT=disterl \
  MIX_ENV=prod mix atomvm.packbeam
```

完了行には RTT の min / average / max、retry に至った pong timeout 数、起動からの経過時間が表示されます。
transport は UART / RTU receive buffer に残った以前の boot session の packet を識別して破棄します。両 node の
ほぼ同時の reset からも自動的に再同期することを実機確認しています。

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
| `MODBUS_BULK_RESPONSE_TIMEOUT_MS` | `2000` | multi-chunk write 後の transaction timeout |
| `MODBUS_CHUNK_PAYLOAD_BYTES` | `96` | virtual UART の operating chunk size（protocol 上限は 232） |
| `MODBUS_MAX_QUEUED_BYTES` | `8192` | in-flight と pending を合わせた outgoing payload byte 上限 |
| `MODBUS_MAX_QUEUED_CHUNKS` | `256` | in-flight と pending を合わせた outgoing chunk 数上限 |
| `MODBUS_POLL_INTERVAL_MS` | `1000` / `20` | Phase 1 / Phase 2 polling interval |
| `MODBUS_TRACE_TRANSACTIONS` | unset | `1` / `true` で non-idle transaction と全 failure の size、latency、累積成否を記録 |
| `MODBUS_TRACE_QUEUE` | unset | `1` / `true` で queue state と ESP32 heap 指標を記録 |
| `MODBUS_WAIT_FOR_PEER` | Phase 2 Clientのみ `true` | `net_kernel`開始前にFC-100 peer responseを待つ |
| `MODBUS_FAULT_DROP_RESPONSES` | `0` | Server が受理後に exception へ置き換える FC-100 response 数 |
| `MODBUS_FAULT_MIN_PAYLOAD_BYTES` | `96` | response fault の対象にする最小 transport payload size |
| `MODBUS_FAULT_AFTER_MS` | `10000` | Server adapter 起動から response fault を有効にするまでの delay |
| `MODBUS_START_DELAY_MS` | `0` | readiness gateとは独立した追加startup delay |
| `ATOMVM_NODE_ALIAS` | role から `a` / `b` | local node alias |
| `ATOMVM_PEER_ALIAS` | role から `b` / `a` | peer node alias |
| `ATOMVM_COOKIE` | `AtomVM` | distribution cookie |
| `DISTERL_PING_COUNT` | `3` | remote ping 回数 |
| `DISTERL_PING_DELAY_MS` | `2000` | 最初の ping と、成功または timeout 後の次の ping までの delay |
| `DISTERL_PONG_TIMEOUT_MS` | `15000` | pong timeout |
| `DISTERL_PAYLOAD_BYTES` | `0` | ping/pong で検証する deterministic payload size |
| `DISTERL_QUEUE_FULL_PROBE_BYTES` | `0` | Client の最初の ping だけに使う queue-full 診断 payload size |

これらは `Application.compile_env/3` で application に埋め込まれます。値を変更する
ときは `mix clean` して、同じ environment で pack / flash してください。

Phase 2 Clientのreadiness gateはModbusUARTを一度だけopenし、有効なFC-100 responseを観測した同じPIDを
`serial_dist`へ引き渡します。Server不在中はphysical pollだけをretryし、AtomVMのdistribution setupを開始しません。
調査時に旧動作を再現する場合は`MODBUS_WAIT_FOR_PEER=false`でbuildできます。`MODBUS_START_DELAY_MS`は手動試験用に
残しますが、defaultの起動順序mitigationには使用しません。

96-byte の operating chunk を超える genuine distribution message を検証する場合は、両 node を同じ
`DISTERL_PAYLOAD_BYTES` と `MODBUS_CHUNK_PAYLOAD_BYTES` で build します。低 baud rate では
`DISTERL_PONG_TIMEOUT_MS` も十分に延ばしてください。232 bytes は wire protocol の上限ですが、今回の XIAO / HW-519
構成では上限付近の RTU frame が安定しないため default にはしません。実測結果は
[bidirectional multi-chunk round trip](docs/worklog/2026-10-16-bidirectional-multichunk.md) を参照してください。

outgoing queue は byte 数と chunk 数の両方で制限します。1 回の write 全体が収まらない場合は partial data を
queue に残さず `{:error, :queue_full}` を返し、`serial_dist` connection を fail fast させます。既定の 8 KiB は
payload の合計だけを数えるため、ESP32-C5 の厳密な heap 使用量上限ではありません。また `serial_dist` は adapter を
呼ぶ前に frame binary を構築するため、この上限は upstream allocation を防ぎません。16 KiB probe は queue check 前に
OOM、8 KiB cap の 8,304-byte write は正常に queue-full となったため default を下げました。設計理由は
[ADR 0008](docs/adr/0008-bound-the-virtual-uart-queue.md) と
[ADR 0010](docs/adr/0010-reduce-default-queue-byte-limit.md) を参照してください。

queue-full時はlocal FC-100 sessionも更新します。継続するpollでpeerへstream boundaryを通知し、peerの旧
`serial_dist` readerを閉じて両側controllerを終了させます。実機では最初のoversize pingがtimeoutした後、通常payloadの
retryでdistribution handshakeとping/pongを再確立しました。この回復範囲とdata loss semanticsは
[ADR 0011](docs/adr/0011-roll-session-on-queue-full.md) に記録しています。

`MODBUS_FAULT_*`、`MODBUS_TRACE_QUEUE`、`DISTERL_QUEUE_FULL_PROBE_BYTES` は fault / memory 調査専用です。
通常の使用例では設定しません。response fault は Server が request を Channel に受理した後で response だけを
`server_device_failure` に置き換えるため、Client の同一 sequence 再送と Server の duplicate suppression を実機で
確認できます。再現条件と観測値は
[Queue memory と ACK-loss](docs/worklog/2026-10-16-queue-memory-and-ack-loss.md) に記録しています。

## References

- [AtomVM](https://github.com/atomvm/AtomVM)
- [AtomVM distributed Erlang documentation](https://doc.atomvm.org/release-0.7/distributed-erlang.html)
- [direct UART serial distribution experiment](https://github.com/mnishiguchi/hello_atomvm_serial_disterl)
- [AVModbus](https://github.com/piyopiyoex/avmodbus)
