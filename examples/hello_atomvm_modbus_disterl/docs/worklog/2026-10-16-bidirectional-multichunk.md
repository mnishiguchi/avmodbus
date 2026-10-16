# Bidirectional multi-chunk round trip — 2026-10-16

## 目的

512-byte genuine distribution payload の Client-to-Server 配送だけでなく、Server の echo を Client で再構成・検証し、
双方向 round trip を完了する。

## 調査

9,600 baud、20 ms poll interval、transaction tracing 有効で 2 台の XIAO ESP32-C5 を同時 reset して比較した。

- 232-byte chunk、1,000 ms bulk timeout: 245-byte FC-100 request が timeout し、retry 側で 712–760 ms 後に
  遅延 response を受けた。最終 chunk は連続 timeout になった
- 232-byte chunk、2,000 ms bulk timeout: deadline だけを延ばしても上限付近の frame は安定しなかった
- 128-byte chunk（RTU frame 146 bytes）: 最初の application chunk が Server に届かず連続 timeout になった
- 96-byte chunk（RTU frame 114 bytes）: 全 request / response が完了した

128-byte payload でなく 128-byte RTU frame 付近が実用上の境界になっていると推定したため、protocol 上限 232 bytes は
維持しつつ default operating chunk を 96 bytes にした。また、500 ms の handshake timeout は維持し、multi-chunk
write を検出した後だけ 2,000 ms に切り替える `ResponseTimeout` policy を追加した。

## 成功した構成

- AtomVM `v0.7.0-beta.0`
- 9,600 baud、20 ms poll interval
- handshake timeout 500 ms、bulk timeout 2,000 ms
- operating chunk 96 bytes
- `DISTERL_PAYLOAD_BYTES=512`
- `DISTERL_PING_COUNT=1`
- `DISTERL_PONG_TIMEOUT_MS=60000`
- `MODBUS_TRACE_TRANSACTIONS=1`

Server は 624-byte distribution write を `96 × 6 + 48` bytes として受信し、512-byte application payload の内容を
検証した。echo の 618-byte write は Client が `96 × 6 + 42` bytes として再構成し、同じ payload と確認した。

```text
# Server
modbus_uart: delivered bytes=96  # 6 回
modbus_uart: delivered bytes=48
modbus_disterl: received ping 1 from :a@modbus.local payload_bytes=512
modbus_uart: queued bytes=618

# Client
modbus_uart: response timeout 500 -> 2000 ms after multi-chunk write bytes=624
modbus_uart: delivered bytes=96  # 6 回
modbus_uart: delivered bytes=42
modbus_disterl: received pong 1 from :b@modbus.local rtt_ms=7889 payload_bytes=512
modbus_disterl: complete 1 remote ping/pong messages
```

application chunk の transaction は request 方向 312–348 ms、response 方向 269–341 ms だった。75 秒の観察終了時点で
Client は 230 successful transactions、boot 直後の timeout 1 回を記録し、ping/pong 完了後も tick traffic を継続した。

## 残る範囲

4 KiB payload は 96-byte chunk で未再試験である。232-byte wire capacity の安定化、baud / poll matrix、より長い soak
test も別の roadmap 項目として残す。
