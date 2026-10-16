# ロードマップ

このサンプルは、Modbus RTU 上で genuine distributed Erlang が動作することを確認するという
当初の実験目標を達成しています。一方、carrier としては未完成であり、現在は信頼性と制約の調査を
機能追加より優先します。

実装と実行方法は [サンプル README](../README.md)、現在わかっている問題は
[既知の制約](limitations.md)、実測結果は [作業記録](worklog/README.md) を参照してください。

## 完了した検証

- [x] standalone Mix project と host-side test を追加する
- [x] custom Function Code 100 で双方向 logical message を配送する
- [x] sequence、ACK、再送による順序保証と重複抑止を確認する
- [x] Server の起動遅延後に Client が timeout から復旧することを実機で確認する
- [x] virtual UART adapter を介して `serial_dist` handshake を完了する
- [x] 2 台の XIAO ESP32-C5 間で remote process の ping/pong を確認する

## 次に調査すること

- [x] boot/session ID と session-aware resynchronization を設計し、host test を追加する
- [x] Client だけを reboot しても自動的に再接続できることを host test と実機で確認する
- [x] Server だけを reboot しても自動的に再接続できることを実機で確認する
- [x] 16-bit sequence number の wraparound を実装し、host test で検証する
- [x] 64 KiB byte stream の chunk 分割、再構成、再送を host stress test する
- [x] configurable deterministic payload を genuine distribution ping/pong に追加する
- [x] 512-byte genuine distribution payload の Client-to-Server 配送と内容検証を実機で確認する
- [x] Modbus transaction size、latency、累積 success / failure の opt-in tracing を追加する
- [ ] full-size response timeout を解決し、multi-chunk payload の bidirectional round trip を実機で確認する
- [ ] response 消失、CRC error、連続 timeout を実機または fault injection で検証する
- [ ] baud rate と poll interval ごとの handshake 時間、RTT、timeout の安全域を測定する
- [ ] 長時間接続で tick frame と application traffic が安定して共存することを確認する
- [ ] PackBEAM の `erlang:phash2/2` warning が failure path に与える影響を調査する

## 調査後に判断すること

- [ ] virtual UART adapter を維持するか、専用 `modbus_dist` carrier が必要か判断する
- [ ] 再利用できる部分を AVModbus の一般 API に移す価値があるか判断する
- [ ] example のまま保守するか、独立した experimental project として分離するか判断する

これらは検証結果に基づいて判断し、長期的な方針を変更する場合は新しい
[ADR](adr/README.md) に記録します。

## 今回は対象としないこと

- production-ready distributed Erlang transport
- 3 node 以上の RS485 multidrop
- dynamic node discovery と routing
- full Erlang/OTP distribution compatibility
- 機能検証より先に行う performance optimization
- 実験だけを理由にした AVModbus core の変更
