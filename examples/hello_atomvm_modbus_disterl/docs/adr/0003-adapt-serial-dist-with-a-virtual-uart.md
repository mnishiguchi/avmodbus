# 0003: virtual UART で serial_dist を再利用する

## 背景

AtomVM の `serial_dist` は distribution controller と `dist_util` の handshake を既に実装している。
Phase 1 で確認した Modbus transport のために distribution protocol を再実装すると、既存機構との重複が生じる。

## 決定

- `DisterlProbe.ModbusUART` を `serial_dist` の `uart_module` として指定する
- adapter が `open/read/write/close` の byte-stream API と FC-100 chunk transport を相互変換する
- `net_kernel`、`dist_util`、既存の distribution controller をそのまま利用する
- この proof of concept では専用の `modbus_dist` carrier を実装しない

## 影響

AtomVM core を変更せずに genuine distributed Erlang の handshake と remote process messaging を再利用できる。
adapter は handshake 中に使用される `read(handle, :infinity)` と、失敗後に残る stale reader の置換を扱う必要がある。
Modbus の polling latency は `serial_dist` の固定 setup timer 内に収める必要があり、専用 carrier が不要という判断は
現在の 2-node proof of concept の範囲に限られる。
