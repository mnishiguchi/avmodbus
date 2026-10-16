# Baud-rate / poll-interval matrix — 2026-10-16

## 目的

genuine distribution handshake と steady-state RTT に対する UART baud rate と Client poll interval の影響を測り、
AtomVM の distribution setup timeout に対する実用上の境界を確認する。

## 測定方法

- Seeed Studio XIAO ESP32-C5 × 2
- HW-519 TTL-to-RS485 transceiver × 2
- AtomVM `v0.7.0-beta.0`
- operating chunk 96 bytes
- handshake response timeout 500 ms、bulk timeout 2,000 ms
- `DISTERL_PAYLOAD_BYTES=0`
- `DISTERL_PING_COUNT=3`
- `DISTERL_PING_DELAY_MS=0`
- 各条件につき両 node をほぼ同時に reset して 1 run

Client の最初の `send/2` が connection setup を開始するため、ping 1 RTT を handshake と最初の application round trip を
合わせた upper bound とする。ping 2 と 3 の平均を established RTT とする。これは厳密な benchmark ではなく、
この配線と transceiver での機能境界を探る測定である。

build 時は両 role に同じ設定を渡した。

```sh
ATOMVM_UART_SPEED=9600 MODBUS_POLL_INTERVAL_MS=20 \
  DISTERL_PING_DELAY_MS=0 MODBUS_EXPERIMENT=disterl MIX_ENV=prod \
  mix atomvm.packbeam
```

## 結果

| baud | poll | setup / ping | ping 1 RTT upper bound | established RTT | 観察結果 |
| ---: | ---: | --- | ---: | ---: | --- |
| 9,600 | 20 ms | 成功、3 / 3 | 4,388 ms | 1,326 ms | default baseline |
| 9,600 | 50 ms | 成功、3 / 3 | 3,938 ms | 1,433 ms | boot variance が poll 差より大きい |
| 9,600 | 200 ms | 成功、3 / 3 | 6,255 ms | 2,030 ms | setup timeout への余裕が小さい |
| 9,600 | 500 ms | 成功、3 / 3 | 10,340 ms | 3,228 ms | handshake は first pong より前に完了。安全域とはみなさない |
| 9,600 | 1,000 ms | 失敗、0 / 3 | — | — | `timer_timeout`、遅延 fragment で handshake state が崩れた |
| 19,200 | 20 ms | 成功、3 / 3 | 3,027 ms | 1,085 ms | error なし |
| 38,400 | 20 ms | 成功、3 / 3 | 3,044 ms | 970 ms | error なし |
| 115,200 | 20 ms | 成功、3 / 3 | 2,562 ms | 890 ms | error なし |

9,600 baud では poll interval を 500 ms から 1,000 ms にすると distribution setup が完了しなくなった。500 ms は
single run の成功点にすぎず、boot timing や bus error を含む安全域ではない。20 ms は今回の全 baud rate で成功した。

baud rate を 19,200、38,400、115,200 と上げるにつれて established RTT は短縮したが、38,400 以降の改善は小さい。
20 ms の RTU silence、poll scheduling、stop-and-wait transaction 数が wire transmission time より支配的になったためと
推定する。

以前の 115,200-baud failure は session synchronization 修正前の結果であり、zero-byte handshake については再現しなかった。
その後、115,200 baud で 512-byte multi-chunk traffic の 30-message soak と 4 KiB round trip を完了した。結果は
[115,200 baud での payload 検証](2026-10-16-high-baud-payloads.md) に記録している。4 KiB は single run であり、
実績範囲が最も広い 9,600 baud / 20 ms を引き続き default とする。
