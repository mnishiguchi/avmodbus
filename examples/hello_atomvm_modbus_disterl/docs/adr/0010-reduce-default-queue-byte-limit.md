# 0010: outgoing queue の default byte 上限を 8 KiB に下げる

## 背景

[ADR 0008](0008-bound-the-virtual-uart-queue.md) では outgoing payload を default 16 KiB / 256 chunks に
制限した。しかし XIAO ESP32-C5 の実機試験で 16 KiB application payload を送ると、virtual UART の
`write/2` に到達する前に `serial_dist_controller` が 16,496-byte frame を確保できず OOM になった。

queue limit は adapter が受け取った binary に適用されるため、`serial_dist` がその binary を構築するための
先行 allocation を防げない。16 KiB を board 上の安全な default とみなす根拠はなくなった。

## 決定

- default の `MODBUS_MAX_QUEUED_BYTES` を 16,384 bytes から 8,192 bytes に下げる
- 256-chunk 上限と atomic queue rejection は維持する
- 8 KiB 以上が必要な場合は build-time configuration で明示的に引き上げ、対象 hardware で free heap と
  largest free block を再測定する
- queue limit は upstream の `serial_dist` frame allocation を保護しないことを明記する

この判断は ADR 0008 の byte default だけを置き換え、bounded FIFO、chunk limit、fail-fast policy は維持する。

## 影響

現行の 4 KiB genuine distribution payload は 4,208-byte write として収まり、引き続き配送できる。8 KiB
application payload は 8,304-byte write となり、adapter が `{:error, :queue_full}` を返すことを実機確認した。

queue-full 後の distribution controller は `serial_write_error` で終了するが、同じ run の再接続は handshake の
`crc_error` で失敗した。上限を下げることで OOM は避けられるが、controller recovery は AtomVM 側の
half-open connection cleanup が解決するまで保証しない。
