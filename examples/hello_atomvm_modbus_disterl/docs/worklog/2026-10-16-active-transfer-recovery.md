# 4 KiB 転送中の Server reboot recovery — 2026-10-16

## 目的

確立済みの genuine distributed Erlang connection で 4 KiB message を chunk 分割している途中に Server を
再起動し、古い partial stream の破棄、session resynchronization、distribution handshake、application message の
再送まで自動復旧できるか確認する。

## 構成

- Board A / Client: XIAO ESP32-C5、`/dev/ttyACM1`、USB serial `38:44:BE:A5:05:14`
- Board B / Server: XIAO ESP32-C5、`/dev/ttyACM0`、USB serial `38:44:BE:A5:04:DC`
- HW-519 TTL-to-RS485 transceiver × 2、2-wire RS485
- AtomVM `v0.7.0-beta.0+git.8d3e051`
- 9,600 baud、20 ms poll interval、96-byte operating chunk
- handshake response timeout 500 ms、bulk response timeout 2,000 ms

両 role に次の設定を埋め込んだ。

```text
DISTERL_PAYLOAD_BYTES=4096
DISTERL_PING_COUNT=2
DISTERL_PING_DELAY_MS=2000
DISTERL_PONG_TIMEOUT_MS=60000
```

## 手順

1. Server を reset し、boot 完了後に Client を reset する
2. ping 1 の 4 KiB round trip を完了し、connection が確立したことを確認する
3. Client が ping 2 を送信し、Server が最初の 96-byte application chunk を受信した直後に Server を hard reset する
4. Client の session 変更検出、pong timeout、ping 2 の再送、payload 検証を観察する

Server console の `received ping 1` に続く最初の `delivered bytes=96` を `tio` script で待ったため、reset 位置は
ping 2 の 4,208-byte stream の最初の chunk の直後に固定されている。

## 結果

ping 1 は正常に完了した。

```text
modbus_disterl: received pong 1 from :b@modbus.local rtt_ms=36017 payload_bytes=4096
modbus_disterl: first remote reply connection_ms=38199
modbus_disterl: sending ping 2 to :b@modbus.local payload_bytes=4096
modbus_uart: queued bytes=4208
```

Server が ping 2 の最初の chunk を受信した直後、14:44:59.465 に reset した。

```text
modbus_uart: delivered bytes=96
[14:44:59.465] Setting RTS to LOW
[14:44:59.567] Setting RTS to HIGH
```

Client は RTU timeout の後に新しい Server session を検出し、古い byte stream と `serial_dist` reader を終了した。
`{serial_read_error, closed}` の crash report は既知の回復経路であり、Client board 自体は再起動していない。

```text
modbus_uart: poll failed :timeout; retrying
modbus_uart: peer session changed 3636415707 -> 3432532497; resetting stream
CRASH
======
...
x[1]: {serial_read_error,closed}
```

60 秒の application pong timeout 後、Client は同じ ping ID を再送した。新しい distribution handshake の
32 / 37 / 29-byte writes に続いて 4,208-byte application stream が queue され、Server は再構成した payload の
size と内容を検証した。Server の 4,202-byte pong も Client で再構成、検証された。

```text
modbus_disterl: pong 2 timed out; retrying
modbus_disterl: sending ping 2 to :b@modbus.local payload_bytes=4096
modbus_uart: queued bytes=32
modbus_uart: queued bytes=37
modbus_uart: queued bytes=29
modbus_uart: queued bytes=4208

modbus_disterl: received ping 2 from :a@modbus.local payload_bytes=4096
modbus_uart: queued bytes=4202

modbus_disterl: received pong 2 from :b@modbus.local rtt_ms=36212 payload_bytes=4096
modbus_disterl: complete 2 remote ping/pong messages rtt_min_ms=36017 rtt_avg_ms=36114 rtt_max_ms=36212 timeouts=1 elapsed_ms=138551
```

- application payload round trip: 2 / 2 成功
- payload validation error: 0
- recovery に伴う pong timeout: 1
- RTT min / average / max: 36,017 / 36,114 / 36,212 ms
- Client 起動から完了まで: 138,551 ms
- 完了後約 70 秒に `net_tick_timeout`、session change、distribution shutdown は発生しなかった
- 同じ idle 観察中に RTU poll timeout を 2 回記録した。adapter は retry を継続したが、その後に新しい
  application ping は送っていないため、この idle 観察だけを追加の message-delivery 成功とはみなさない

以上により、確立済み connection の 4 KiB stream を Server reboot で中断しても、partial stream を application へ
誤配送せず、1 回の application timeout 後に同じ message を再送して genuine distribution messaging を復旧できた。
これは 1 run の結果であり、任意の reboot timing や連続 fault を保証するものではない。

## 準備中に見つかった startup race

両 node を直前の traffic が残った状態からほぼ同時に reset し、Client が Server より約 1〜2 秒先に起動した条件では、
Client が initial handshake 中に以前の Server session を観測した後、現在の session への変更を検出した。

```text
modbus_uart: peer session changed 3604015592 -> 1065242002; resetting stream
dist_util: shutting down connection ... reason=closed
```

この条件を 2 run で観測し、60 秒ごとの application ping retry は表示されたが、新しい handshake write は開始されなかった。
Server-first の controlled startup では発生せず、確立済み connection の reboot recovery は上記のとおり成功した。

これは既に修正した「stale frame を新しい reader へ配送する」問題とは異なり、initial handshake を session change で
終了した後の connection 再試行が進まない liveness 問題に見える。transport、`serial_dist` link manager、application retry の
どこで明示的な再接続 trigger が必要かを、host で再現してから修正する。

follow-upのsource調査では、AtomVM `net_kernel`のpending entryとpeer側half-open connectionを同時に扱う必要があり、
example-localなsetup retryは安全でないと判断した。default Client startupを3秒遅らせるmitigationと2 runの実機結果は
[initial-handshake livenessの調査](2026-10-16-initial-handshake-liveness.md)に記録している。根本のretry lifecycleは
引き続き未解決である。

試験後、両 board は 9,600 baud / 20 ms poll / zero-byte payload の default distributed Erlang firmware へ戻した。
