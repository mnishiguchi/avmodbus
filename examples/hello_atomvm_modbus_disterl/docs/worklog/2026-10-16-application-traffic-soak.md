# Application-traffic soak test — 2026-10-16

## 目的

短い疎通確認より長く genuine distribution connection を維持し、`serial_dist` の tick frame と継続的な
multi-chunk application traffic が共存できるか確認する。また、run 全体の RTT と timeout を再現可能な形で記録する。

## 計測機能

`DisterlProbe.PingStats` を追加し、正常な pong の RTT min / average / max と retry に至った pong timeout 数を
Client の完了行へ集計する。集計ロジックは host test で検証した。

## 構成

- Seeed Studio XIAO ESP32-C5 × 2
- HW-519 TTL-to-RS485 transceiver × 2
- AtomVM `v0.7.0-beta.0`
- 9,600 baud、20 ms poll interval
- handshake timeout 500 ms、bulk timeout 2,000 ms
- operating chunk 96 bytes
- `DISTERL_PAYLOAD_BYTES=512`
- `DISTERL_PING_COUNT=30`
- `DISTERL_PONG_TIMEOUT_MS=60000`

Server と Client はそれぞれ 512-byte deterministic payload の内容を検証した。Client-to-Server の 624-byte
distribution write は `96 × 6 + 48` bytes、Server-to-Client の 618-byte echo は `96 × 6 + 42` bytes に分割された。

## 結果

Server を動作させたまま Client だけを reset した後、30 回すべての ping/pong が連続して成功した。

```text
modbus_disterl: received pong 30 from :b@modbus.local rtt_ms=5482 payload_bytes=512
modbus_disterl: complete 30 remote ping/pong messages rtt_min_ms=5250 rtt_avg_ms=5425 rtt_max_ms=7477 timeouts=0 elapsed_ms=223327
```

- application payload round trip: 30 / 30 成功
- payload validation error: 0
- pong timeout / retry: 0
- RTT min / average / max: 5,250 / 5,425 / 7,477 ms
- Client 起動から完了まで: 223,327 ms（約 3 分 43 秒）
- 完了後 45 秒の idle 観察中も `net_tick_timeout` や connection shutdown は発生しなかった

この間に複数の distribution tick interval をまたぎ、connection を張り直さず application message を配送し続けた。
この条件では tick frame と multi-chunk traffic が安定して共存したと判断する。より長時間の soak、4 KiB payload、
baud / poll matrix は別の調査範囲である。

## 同時 reset で見つかった startup race

最初の試行では両 node を monitor からほぼ同時に reset した。Client は boot 直後の 2 回の poll timeout 後、
`invalid_acknowledgment` を繰り返し、distribution setup は `timer_timeout` で終了した。自動収束はしなかった。

Server を動作させたまま Client だけを reset すると、Server は Client の session 変更を検出した。

```text
modbus_uart: peer session changed 2384873094 -> 973046600; resetting stream
```

その後は handshake と上記 30-message run が完了した。このため片側 reboot の recovery は再確認できたが、両側が
近接して boot する場合の ACK / sequence synchronization には未解決の race がある。roadmap に独立した調査項目として残す。

この race は同日の follow-up で修正した。原因と再検証結果は
[simultaneous-startup recovery](2026-10-16-simultaneous-startup-recovery.md) を参照する。

115,200 baud でも後日同じ 512-byte payload を 30 往復し、timeout なしで完了した。比較条件と測定値は
[115,200 baud での payload 検証](2026-10-16-high-baud-payloads.md) に記録している。
