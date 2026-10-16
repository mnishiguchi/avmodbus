# 115,200 baud での 512-byte soak と 4 KiB baud comparison — 2026-10-16

## 目的

baud / poll matrix では 115,200 baud の zero-byte ping/pong まで確認していたが、multi-chunk traffic と
長時間接続は未検証だった。また、4 KiB payload は旧 232-byte chunk / 9,600 baud の試験で
`net_tick_timeout` になり、現行の 96-byte operating chunk では再試験していなかった。

そこで、115,200 baud / 20 ms poll で次を順に確認した。

1. 512-byte payload の 30-message soak
2. 4 KiB payload の 1-message bidirectional round trip
3. 4 KiB round trip 完了後の idle connection
4. 同じ 4 KiB payload の 9,600-baud comparison

## 構成

- Board A / Client: XIAO ESP32-C5、`/dev/ttyACM1`、USB serial `38:44:BE:A5:05:14`
- Board B / Server: XIAO ESP32-C5、`/dev/ttyACM0`、USB serial `38:44:BE:A5:04:DC`
- HW-519 TTL-to-RS485 transceiver × 2
- 2-wire RS485
- AtomVM `v0.7.0-beta.0+git.8d3e051`
- 115,200 baud、20 ms poll interval
- handshake response timeout 500 ms、bulk response timeout 2,000 ms
- operating chunk 96 bytes

両 node は同じ payload、ping count、timeout で clean、pack、flash した。console を接続した後、`tio` の
DTR / RTS script で両 node を reset し、boot から結果までを観察した。

## 512-byte soak

追加設定:

```text
DISTERL_PAYLOAD_BYTES=512
DISTERL_PING_COUNT=30
DISTERL_PING_DELAY_MS=0
DISTERL_PONG_TIMEOUT_MS=60000
```

Client-to-Server の 624-byte distribution write は `96 × 6 + 48` bytes、Server-to-Client の
618-byte echo は `96 × 6 + 42` bytes に分割された。Server は 30 個すべての payload を検証し、Client は
30 個すべての echo を検証した。

```text
modbus_disterl: received pong 30 from :b@modbus.local rtt_ms=3255 payload_bytes=512
modbus_disterl: complete 30 remote ping/pong messages rtt_min_ms=3245 rtt_avg_ms=3311 rtt_max_ms=4923 timeouts=0 elapsed_ms=99877
```

- application payload round trip: 30 / 30 成功
- payload validation error: 0
- pong timeout / retry: 0
- RTT min / average / max: 3,245 / 3,311 / 4,923 ms
- Client 起動から完了まで: 99,877 ms

9,600 baud の既存 soak では RTT min / average / max が 5,250 / 5,425 / 7,477 ms だったため、今回の
average RTT は約 39% 短かった。ただし既存 soak は ping 間に 2 秒の delay があり、今回の
`DISTERL_PING_DELAY_MS=0` とは条件が異なるため、run 全体の elapsed time は直接比較しない。

## 4 KiB round trip — 115,200 baud

追加設定:

```text
DISTERL_PAYLOAD_BYTES=4096
DISTERL_PING_COUNT=1
DISTERL_PING_DELAY_MS=0
DISTERL_PONG_TIMEOUT_MS=120000
```

Client は 4,208-byte stream を `96 × 43 + 80` bytes に分割し、Server は payload の size と内容を検証した。
Server の 4,202-byte echo は `96 × 43 + 74` bytes に分割され、Client も内容を再検証した。

```text
modbus_disterl: received ping 1 from :a@modbus.local payload_bytes=4096
modbus_uart: queued bytes=4202
modbus_disterl: received pong 1 from :b@modbus.local rtt_ms=22617 payload_bytes=4096
modbus_disterl: complete 1 remote ping/pong messages rtt_min_ms=22617 rtt_avg_ms=22617 rtt_max_ms=22617 timeouts=0 elapsed_ms=22799
```

- application payload round trip: 1 / 1 成功
- payload validation error: 0
- pong timeout / retry: 0
- RTT: 22,617 ms
- Client 起動から完了まで: 22,799 ms
- 完了後 30 秒の idle 観察中に `net_tick_timeout`、connection shutdown、追加 error は発生しなかった

## 4 KiB round trip — 9,600 baud

baud rate だけを default の 9,600 へ戻し、同じ 96-byte chunk、payload、ping count、timeout で再実行した。
stream size と chunk 分割は 115,200-baud run と同じである。

```text
modbus_disterl: received ping 1 from :a@modbus.local payload_bytes=4096
modbus_uart: queued bytes=4202
modbus_disterl: received pong 1 from :b@modbus.local rtt_ms=36051 payload_bytes=4096
modbus_disterl: complete 1 remote ping/pong messages rtt_min_ms=36051 rtt_avg_ms=36051 rtt_max_ms=36051 timeouts=0 elapsed_ms=36233
```

- application payload round trip: 1 / 1 成功
- payload validation error: 0
- pong timeout / retry: 0
- RTT: 36,051 ms
- Client 起動から完了まで: 36,233 ms
- 完了後 30 秒の idle 観察中に `net_tick_timeout`、connection shutdown、追加 error は発生しなかった

## 判断

115,200 baud / 20 ms poll / 96-byte chunk では、512-byte traffic を 30 往復しながら connection を維持できた。
また、4 KiB の genuine distribution message は 9,600 baud と 115,200 baud の両方で双方向へ 1 往復でき、
旧 232-byte chunk 構成で発生した `net_tick_timeout` は再現しなかった。この比較は operating chunk の縮小が
安定化に寄与したことを示すが、single run のため failure 原因を chunk size だけに限定はできない。

一方、4 KiB は各 baud で single run であり、連続 traffic や reboot recovery は未検証である。default は
実績範囲の広い 9,600 baud / 20 ms のままとし、115,200 baud を一般的な安定動作として保証しない。

試験後、両 board は 9,600 baud / 20 ms poll / zero-byte payload の default distributed Erlang firmware へ戻した。
