# Byte-stream stress test — 2026-10-16

## 目的

`serial_dist` から Modbus virtual UART へ渡される大きな write が、FC-100 payload 上限を超えても
byte 順序を維持し、response 消失による再送で重複しないことを host 上で検証する。

## 方法

- 64 KiB の deterministic binary pattern を `ModbusUART.queue_chunks/2` に渡す
- 232-byte 以下の transport chunk 283 個として stop-and-wait channel へ queue する
- Client と Server の `Channel` を host 上で exchange する
- 7 chunk ごとに、Server が request を受理した後の response 消失を模擬する
- 同一 request を再送し、duplicate delivery が発生しないことを確認する
- 配達された chunk を順番に連結し、元の 64 KiB binary と比較する

## 結果

283 chunk と 40 回の再送を経て、byte 欠落、順序逆転、重複なしに元の payload を再構成できた。
空の UART write が transport message を生成しないことも別 test で確認した。

この test は actual Modbus RTU timing、UART error、AtomVM heap pressure、または genuine distribution frame を
検証するものではない。これらは roadmap の実機試験として残す。
