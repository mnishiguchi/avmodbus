# 0008: virtual UART の outgoing queue を制限する

## 背景

16-bit sequence number により未 ACK chunk は最大 65,535 個に制限されるが、ESP32-C5 の実用的なメモリ上限としては
大きすぎる。また、pending list 末尾への `pending ++ [message]` は enqueue ごとに list 全体を走査する。

この transport を reusable library にしない現在の段階でも、peer が ACK を返さない場合や `serial_dist` が大きな
write を発行した場合に、example が無制限に近い queue を保持する設計は避ける。

## 決定

- in-flight と pending を合わせた outgoing payload を default 16,384 bytes / 256 chunks に制限する
- `MODBUS_MAX_QUEUED_BYTES` と `MODBUS_MAX_QUEUED_CHUNKS` で build ごとに変更できるようにする
- pending FIFO は front / rear の two-list queue とし、enqueue / dequeue を amortized O(1) にする
- 1 回の virtual UART write を chunk 分割した結果が上限を超える場合、その write の partial state を commit せず
  `{:error, :queue_full}` を返す
- `ModbusUART.write/2` は error を `serial_dist` へ返し、controller を `serial_write_error` で終了させる。queue 空きを
  無期限に待つ backpressure や silent drop は実装しない
- peer session 変更時は従来どおり queue と byte / chunk counter を 0 に戻す

## 影響

既定値では 4 KiB distribution traffic を複数 frame に分割できる一方、過大な write や ACK 停止時の保持量に上限が付く。
上限は payload binary の byte 数だけを数え、Elixir term、list cell、binary header、protocol header などの runtime
overhead は含まない。そのため厳密な heap budget ではなく、実用上の guardrail である。

上限を引き上げる場合は `.avm` size だけでなく、対象 board 上の free heap と長時間の ACK-loss behavior を再測定する。
