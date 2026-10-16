# Large distribution payload — 2026-10-16

## 目的

232-byte の FC-100 payload 上限を超える genuine distributed Erlang message を 2 台の XIAO ESP32-C5 間で
送受信し、virtual UART の chunk 分割と再構成を実機で確認する。

## 実装

`DISTERL_PAYLOAD_BYTES` を追加した。Client は指定 byte 数の deterministic binary を remote ping に含める。
Server は size と内容を検証して同じ binary を pong で返し、Client も local copy と一致することを確認する。
default は従来と同じ 0 bytes である。

payload pattern の exact size、determinism、破損検出を host test に追加した。example 全体では 21 tests が
成功し、PackBEAM は当時既知だった `erlang:phash2/2` warning だけで完了した。この warning は後の
[調査と callback の明示実装](2026-10-16-packbeam-phash2.md) で除去した。

## 4 KiB、9,600 baud

両 node を `DISTERL_PAYLOAD_BYTES=4096`、Client を `DISTERL_PING_COUNT=1`、
`DISTERL_PONG_TIMEOUT_MS=60000` で build した。distribution handshake 後、Client は external term を含む
4,208-byte stream を queue した。

```text
modbus_disterl: sending ping 1 to :b@modbus.local payload_bytes=4096
modbus_uart: queued bytes=4208
```

Server は 232-byte chunk を受信したが、round trip 完了前に connection が tick timeout になった。

```text
modbus_uart: delivered bytes=232
dist_util: shutting down connection ..., reason=net_tick_timeout
```

## Baud rate と timeout の試行

- 115,200 baud では handshake が安定せず、`timer_timeout`、`unexpected <<"sok">>`、
  `unsupported_name` が発生した。
- `MODBUS_RESPONSE_TIMEOUT_MS=2000` を handshake から一律に使うと、AtomVM の 7 秒 setup timeout 内での
  recovery が悪化した。
- handshake 後だけ長い timeout に切り替える試作も行ったが、今回の hardware state では安定した baseline を
  再現できず、根拠の弱い変更になるため採用しなかった。

## 512-byte payload

9,600 baud、500 ms Modbus response timeout に戻し、512-byte payload を試した。Server は transport chunk
`232 + 232 + 160` bytes を再構成し、genuine distribution message の payload を検証できた。

```text
modbus_uart: delivered bytes=232
modbus_uart: delivered bytes=232
modbus_uart: delivered bytes=160
modbus_disterl: received ping 1 from :a@modbus.local payload_bytes=512
modbus_uart: queued bytes=618
```

一方、Server からの echo は full-size Modbus response で Client の transaction timeout を繰り返し、
Client に complete pong として届く前に両 node が `net_tick_timeout` になった。このため、実機で確認できたのは
multi-chunk の Client-to-Server 配送までであり、bidirectional round trip は未達である。

試験後に両 board を default の zero-byte firmware へ戻したが、繰り返した timeout 試験の後は baseline
handshake も安定しなかった。USB device reset には host の sudo 認証が必要だったため、次回は board と
HW-519 を power-cycle して baseline を再確認してから測定を再開する。

## 次の調査

1. board と transceiver を power-cycle し、zero-byte baseline を再確認する
2. request size、response size、成功数、timeout 数、transaction latency を計測可能にする
3. handshake の 7 秒 budget を維持しながら full-size response に十分な deadline を与える方法を検討する
4. 512 bytes、1 KiB、4 KiB の順で bidirectional round trip を再試験する

512-byte round trip は後の試験で 96-byte operating chunk を使って完了した。調査と実測値は
[Bidirectional multi-chunk round trip](2026-10-16-bidirectional-multichunk.md) を参照する。1 KiB と 4 KiB は未再試験である。
