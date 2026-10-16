# ロードマップ

このサンプルは、Modbus RTU 上で genuine distributed Erlang を動かすという当初の実験目標を達成しています。
現在は新機能を増やす段階ではなく、experimental example として確認済みの範囲を維持しながら、残る制約を
測定する段階です。

実装と実行方法は [サンプル README](../README.md)、現在わかっている問題は
[既知の制約](limitations.md)、個々の実測結果は [作業記録](worklog/README.md) を参照してください。
このページでは現在地と、今後の follow-up の優先順位だけを管理します。

## 現在地

| 項目 | 状態 | 確認済みの範囲 |
| --- | --- | --- |
| Phase 1: logical transport | 完了 | FC-100、双方向配送、順序保証、ACK、再送、重複抑止 |
| Phase 2: genuine distribution | 完了 | `serial_dist` handshake、remote process の ping/pong |
| session recovery | 完了 | client-only / server-only reboot、simultaneous startup、active-transfer reboot |
| resource protection | 完了 | 8 KiB / 256 chunks の queue 上限、queue-full 時の session rollover |
| startup liveness mitigation | 完了 | Client の peer readiness gate、Server の idle sync marker coalescing |
| hardware baseline | 完了 | XIAO ESP32-C5 2 台、9,600 / 115,200 baud、512-byte soak、4 KiB traffic |
| package boundary | 決定済み | carrier は AVModbus core に移さず、この example 内に維持 |
| AtomVM setup retry fix | upstream follow-up | local patch と実機 A/B は完了、公式 release には未収録 |

詳細な経緯をこの表へ重複させず、各結果は [作業記録](worklog/README.md)、長期的な判断は
[ADR](adr/README.md) を正とします。

## 今回の follow-up で完了した範囲

- [x] outgoing queue を payload byte 数と chunk 数で制限し、amortized O(1) の FIFO にする
- [x] queue-full を recoverable な transport session boundary として扱う
- [x] reader lifecycle、session rollover、queue recovery を host test で固定する
- [x] Client-first / Server-first の起動順序に対する mitigation を追加する
- [x] 512-byte soak、4 KiB traffic、active-transfer reboot、limited ACK loss を実機で確認する
- [x] AtomVM `net_kernel` の early setup failure を再現し、最小修正を新旧 boot library の実機 A/B で確認する
- [x] carrier を example に維持する判断と、残る制約を ADR / worklog / README に記録する
- [x] AVModbus core と既存 example を変更せず、standalone example の host test を通す

この範囲で experimental example の follow-up は完了とします。以下の項目は現在の PR の完了条件ではなく、
マージ後に追加の根拠を得るための候補です。

## マージ後に確認すること

- [ ] AtomVM の setup PID 修正を upstream PR として提案し、取り込まれた release の boot library で
  failure-injection と ping/pong recovery を再確認する
- [ ] 9,600 baud の default 構成で数時間の soak test を行い、queue、free heap、timeout 数の推移を記録する
- [ ] 長時間の ACK loss と通信断・復旧の反復試験を行い、memory stability と session rollover の収束を確認する
- [ ] 16-bit sequence が実際に wraparound するまで実機 traffic を継続し、host test の結果を補強する
- [ ] 115,200 baud で 4 KiB payload の連続 traffic と active-transfer reboot を複数 run 実施する

新しい検証を行うときは、先に成功条件と停止条件を決め、結果を `docs/worklog/` に追加します。単発の成功を
一般的な保証へ広げず、再利用可能な API が必要になった場合だけ package boundary を再検討します。

## 現在わかっている制約

この carrier は proprietary FC-100 を使う 2-node proof of concept です。durable delivery、exactly-once、
multidrop、direct UART 相当の latency は保証しません。queue 上限、実測済み payload、AtomVM patch の状態を含む
詳細は [既知の制約](limitations.md) を正とします。

## 判断したこと

- [x] proprietary FC-100 carrier は AVModbus の一般 API に移さない
- [x] 現時点では独立 package に分離せず、example のまま保守する
- [x] 2-node proof of concept では virtual UART adapter を維持し、専用 `modbus_dist` carrier は実装しない

package boundary は [ADR 0012](adr/0012-keep-the-carrier-in-the-example.md)、virtual UART の判断は
[ADR 0003](adr/0003-adapt-serial-dist-with-a-virtual-uart.md) に記録しています。example 外の具体的な利用者と
安定した lifecycle contract が得られた場合に再検討します。

## 今回は対象としないこと

- production-ready distributed Erlang transport
- 3 node 以上の RS485 multidrop
- dynamic node discovery と routing
- full Erlang/OTP distribution compatibility
- 機能検証より先に行う performance optimization
- 実験だけを理由にした AVModbus core の変更
