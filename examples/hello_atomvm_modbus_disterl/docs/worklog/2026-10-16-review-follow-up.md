# 外部 review follow-up — bounded queue と RTU frame size — 2026-10-16

## 目的

実験 example の source / documentation review で挙がった指摘を現在の branch と照合し、再利用性を広げずに
proof of concept の安全性と記録精度を改善する。

主な指摘は次のとおりだった。

1. sequence 空間だけでは ESP32-C5 上の実用的な queue memory bound にならない
2. `pending ++ [message]` は queue が伸びるほど enqueue cost が増える
3. lifecycle と queue-full behavior を明文化する必要がある
4. 96-byte transport payload の RTU frame size は 114 bytes ではなく 113 bytes である
5. 4 KiB payload の現行 96-byte chunk による再検証が必要である

5 は review 対象時点より後の worklog で既に完了していた。9,600 / 115,200 baud の round trip、9,600 baud の
3-message consecutive traffic、active-transfer reboot recovery はそれぞれ別の記録に残している。

## Queue の変更

`DisterlProbe.Channel` に次の default 上限を追加した。

- queued payload: 16,384 bytes
- outstanding chunks: 256

どちらも in-flight 1 chunk と pending chunks の合計に適用する。上限は
`MODBUS_MAX_QUEUED_BYTES` / `MODBUS_MAX_QUEUED_CHUNKS` で build 時に変更できる。

pending queue は `{front, rear}` の two-list FIFO へ変更した。enqueue は rear への prepend、front が空になった時だけ
rear を reverse するため、FIFO ordering を保ちながら enqueue / dequeue は amortized O(1) になる。

multi-chunk write が途中で上限に達した場合、再帰中の immutable state は caller の `ModbusUART` state に commit
されない。write 全体を `{:error, :queue_full}` とし、partial stream は残さない。`serial_dist` controller はこの error を
`serial_write_error` として扱い、connection を fail fast する。

これは block して queue 空きを待つ backpressure ではない。また byte counter は payload binary の合計だけで、term や
binary header の heap overhead を含まないため、厳密な memory budget ではない。方針は
[ADR 0008](../adr/0008-bound-the-virtual-uart-queue.md) に記録した。

## Frame size の訂正

FC-100 request / response に 96-byte transport payload を載せた時の RTU ADU は次の 113 bytes である。

```text
Unit ID               1 byte
Function Code         1 byte
Transport header     13 bytes
Transport payload    96 bytes
CRC16                 2 bytes
--------------------------------
RTU ADU              113 bytes
```

同じ式で 128-byte payload は 145-byte RTU ADU になる。architecture、limitations、ADR 0006、過去の
multi-chunk worklog にあった 114 / 146 bytes を 113 / 145 bytes へ訂正し、encode chain を通した test で
transport 109 bytes、PDU 110 bytes、RTU ADU 113 bytes を固定した。

## Host validation

追加した focused test は次を確認する。

- chunk limit 到達時の `:queue_full`
- byte limit 到達時に元の state を変更しないこと
- ACK 後に byte / chunk capacity が解放されること
- multi-chunk write が atomic に拒否されること
- two-list FIFO が既存 ordering、duplicate suppression、wraparound behavior を維持すること
- 96-byte payload の custom PDU / RTU ADU size

```text
40 tests, 0 failures
```

production `mix atomvm.packbeam` も warning なしで完了した。

## 実機 regression

2 台の XIAO ESP32-C5 に bounded queue を含む default distributed Erlang firmware を flash した。Server を先に
reset して boot 完了後に Client を reset し、9,600 baud / 20 ms poll / zero-byte application payload で確認した。

```text
modbus_disterl: received pong 1 from :b@modbus.local rtt_ms=3729 payload_bytes=0
modbus_disterl: received pong 2 from :b@modbus.local rtt_ms=1567 payload_bytes=0
modbus_disterl: received pong 3 from :b@modbus.local rtt_ms=1575 payload_bytes=0
modbus_disterl: complete 3 remote ping/pong messages rtt_min_ms=1567 rtt_avg_ms=2290 rtt_max_ms=3729 timeouts=0 elapsed_ms=13090
```

- genuine distribution handshake: 成功
- remote process ping/pong: 3 / 3 成功
- pong timeout: 0
- queue rejection / process crash: 0

試験後も両 board には同じ default firmware を残した。

## 判断

bounded queue と lifecycle contract は example 内に実装し、AVModbus core は変更しない。FC-100 transport を reusable
library へ移す根拠は増えておらず、既存の分離方針を維持する。

次の memory 調査では default 16 KiB / 256 chunks を nominal heap guarantee とみなさず、ACK-loss 下で実際の free heap、
queue-full、controller shutdown、再接続を実機測定する。
