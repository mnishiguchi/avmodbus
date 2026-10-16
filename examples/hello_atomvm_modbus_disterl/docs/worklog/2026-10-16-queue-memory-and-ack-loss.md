# Queue memory と ACK-loss — 2026-10-16

## 目的

bounded outgoing queue の実メモリ挙動を XIAO ESP32-C5 上で測定し、受理済み FC-100 response の消失時に
再送、重複抑止、queue 排出が成立することを確認する。また queue-full 後に distribution controller が
再接続できるか確認する。

## 診断機能

- `MODBUS_TRACE_QUEUE=1` で queue の open、非 sync write の accepted / rejected、drained 時に payload byte 数、
  chunk 数、ESP32 free heap、largest free block、boot 後の minimum free heap を記録する
- Server の `MODBUS_FAULT_DROP_RESPONSES=N` は request を Channel に受理した後、最初の N response を
  `server_device_failure` exception に置き換える
- `MODBUS_FAULT_AFTER_MS` と `MODBUS_FAULT_MIN_PAYLOAD_BYTES` で handshake を fault 対象から除外する
- Client の `DISTERL_QUEUE_FULL_PROBE_BYTES` は最初の ping だけ指定サイズにし、timeout 後は通常 payload に戻す

response fault は Server state を先に commit する。このため Client は同じ sequence を再送し、Server は duplicate を
application stream へ再配達せず ACK だけを返す。

## 構成

- XIAO ESP32-C5 × 2、HW-519 × 2、two-wire RS485
- AtomVM `v0.7.0-beta.0+git.8d3e051`
- 9,600 baud、20 ms poll、96-byte operating chunk
- `/dev/ttyACM0`: Server、USB serial `38:44:BE:A5:04:DC`
- `/dev/ttyACM1`: Client、USB serial `38:44:BE:A5:05:14`

## 16 KiB probe

default 16 KiB queue に対して 16,384-byte application payload を送った。distribution frame は 16,496 bytesに
なったが、`ModbusUART.write/2` の queue check より前に `serial_dist_controller` が refc binary を確保できなかった。

```text
memory_create_refc_binary: Unable to allocate 16496 bytes for refc_binary.
serial_dist_controller: out_of_memory
```

この run の Client は boot 後 minimum free heap 52,168 bytesまで低下した。queue limit は adapter より上流の frame
allocation を制限できないため、16 KiB default を安全な heap guardrail とみなせない。

## 8 KiB queue-full probe

Client の queue limit と最初の application payload を 8,192 bytes にした。8,304-byte distribution write の
allocation は成功し、adapter が partial chunk を残さず拒否した。

```text
modbus_uart: queue rejected bytes=8304 reason=:queue_full
modbus_uart: queue event=rejected write_bytes=8304 queued_bytes=0 outstanding=0 \
free_heap_bytes=85476 largest_free_block_bytes=45056 minimum_free_heap_bytes=68704
serial_dist_controller: {serial_write_error,queue_full}
```

fail-fast は意図どおりだったが、15秒後の zero-byte ping retry で開始された handshake は `crc_error` になり、remote
ping/pong へ復旧しなかった。queue-full 後の controller recovery は未達であり、initial startup で確認した AtomVM
`net_kernel` / `serial_dist` の half-open connection cleanup と同じ領域の blocker と判断する。

## 4 KiB ACK-loss

default queue に 4,096-byte payload を送信し、Server は起動7秒後から payload 96 bytes以上の受理済み response を
3回失敗させた。Client の distribution write は 4,208 bytes / 44 chunks だった。

```text
modbus_uart: queue event=accepted write_bytes=4208 queued_bytes=4208 outstanding=44 \
free_heap_bytes=92124 largest_free_block_bytes=65536 minimum_free_heap_bytes=85164
modbus_uart: poll failed {:exception, :server_device_failure}; retrying
modbus_uart: poll failed {:exception, :server_device_failure}; retrying
modbus_uart: poll failed {:exception, :server_device_failure}; retrying
modbus_uart: queue event=drained write_bytes=0 queued_bytes=0 outstanding=0 \
free_heap_bytes=95148 largest_free_block_bytes=65536 minimum_free_heap_bytes=85164
```

Server は sequence 12 / 96-byte chunk を最初の1回だけ配達し、その ACK response を3回失敗させた。再送された同じ
sequence の duplicate delivery はなかった。その後残りの chunk と4 KiB echoを配送し、ping/pong は成功した。

```text
modbus_uart: fault dropped accepted response count=1 remaining=2 sequence=12 payload_bytes=96
modbus_uart: fault dropped accepted response count=2 remaining=1 sequence=12 payload_bytes=96
modbus_uart: fault dropped accepted response count=3 remaining=0 sequence=12 payload_bytes=96
modbus_disterl: complete 1 remote ping/pong messages rtt_min_ms=39226 \
rtt_avg_ms=39226 rtt_max_ms=39226 timeouts=0 elapsed_ms=41421
```

Server が4,202-byte echoを queue した時点は free heap 81,856 bytes、largest free block 51,200 bytes、boot 後の
minimum free heap 74,976 bytesだった。drain 後は free heap 87,372 bytesまで戻った。

## 結論

- ACK response が3回失われても、再送、duplicate suppression、queue drain、4 KiB round trip は成立した
- 16 KiB write は queue check より前に OOM になるため、default byte limit を8 KiBへ下げる
- 8 KiB limit の atomic queue-full と controller fail-fast は成立した
- queue-full 後の自動的な distribution recovery は未達で、AtomVM 側の connection cleanup 調査に残す

heap 値には console logging と周辺 process の allocation も含まれるため、厳密な queue 単体の使用量ではなく、この
firmware / run の観測値である。

## 最終 default regression

default byte limit を8 KiBへ変更し、fault / traceを無効にした通常 firmwareを両boardへ書き戻した。両boardを同時に
resetし、Clientのdefault 3秒 startup delayでzero-byte ping/pongを3回実行した。

```text
modbus_disterl: complete 3 remote ping/pong messages rtt_min_ms=1339 \
rtt_avg_ms=2542 rtt_max_ms=4947 timeouts=0 elapsed_ms=13836
```

3 / 3成功、timeout 0で、8 KiB defaultへの変更後も通常のgenuine distribution trafficが成立した。
