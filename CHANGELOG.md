# 変更履歴

## 0.1.0

開発初期版:

- 公開 Function Code に対応する Modbus application protocol の Client / Server
- AtomVM UART adapter 上で通信状態を管理する RTU / ASCII Client / Server
- transaction の並行処理と再接続方針を備えた Modbus TCP Client
- connection の分離と受け入れ数の制限を備えた Modbus TCP Server
- slow handler 中も受信を継続し、connection ごとの未処理 data を制限する TCP receive broker
- overflow、切断、eviction、server stop 時に `trap_exit` の有無によらず実行中の TCP handler も停止する lifecycle ownership
- forced broker death 時の handler cleanup、handoff failure cleanup、共有 deadline による bounded TCP shutdown
- Modbus TCP Client / Server での IPv4 / IPv6 literal 対応
- raw PID と registered name API を利用できる OTP supervision 対応 Client
- raw PID と `stop/1` に lifecycle API を統一した OTP supervision 対応の RTU / ASCII / TCP Server
- transport 間で起動と supervision の入口を統一する `AVModbus.Server`
- Client / Server で共通の、明示指定式 `transport:` startup API
- option、handler、registered name に対する一貫した tagged startup error
- 一時的な timeout / disconnect error に対する、明示指定式の冪等な read retry
- 同期 request の timeout / retry、device identification category、非同期通知を指定する keyword option
- request 単位で上書きできる Client 共通の既定 timeout
- serial gap が不要な即時送信で、結果が一定になる zero-timeout probe
- automatic-direction transceiver の追加 margin に対応する、compile-time の RTU gap 上書き
- AtomVM で未対応の Modbus/TCP Security option を明示的に拒否する fail-closed behavior
- TCP half-close、reset、不正 stream、応答しない peer からの復旧テスト
- 継続する RTU / ASCII noise、checksum 破損、fragmentation、frame burst の stress test
- TCP Client の並行処理、pipelined request、遅い handler に対する load test
- serial timeout、CRC error、disconnect、再 open の反復復旧テスト
- UART read 呼び出し間の byte loss を防ぐ、上限付きの連続受信 buffer
- terminal UART failure を受信済み / 遅延 data より優先し、managed reconnect へ伝える broker
- 明示的な `AVModbus.Serial.Transport` contract と instance ごとの UART 設定
- unknown-length response を含む RTU receive buffer の 256-byte 上限
- serial / TCP queue 負荷時も deadline 内に結果を一度だけ通知する非同期 request
- Serial / TCP の bounded queue を受付前に確認し、overflow を直接返す async admission
- 再現可能な AtomVM production artifact size の確認と、文書化した regression budget
- 明示指定式の ESP32 memory probe と、記録済みの RTU Client / Server footprint baseline
- resource 上限を備え、RTU / ASCII / TCP の Client / Server を設定できる soak test
- device soak 用の、明示指定式 ESP32 定期 health telemetry
- 上限到達と復旧を明示する、サイズ制限付き TCP Client 待機 queue
- AtomVM にない `Map.pop/2` を使わない TCP response / eviction path
- ESP32 の TCP socket / process / heap 負荷と復旧を確認する明示指定式 probe
- ESP32 resource probe を確認済み範囲に保つ fail-closed connection count guard
- Linux file descriptor 枯渇と復旧を確認する明示指定式 integration test
- sparse in-memory data model、diagnostics、broadcast、authorization、device identification
- Modbus V1.1b3 application example と malformed frame の conformance vector
- RTU decode で予約済み Unit ID `248..255` を拒否する serial address validation
- property test と、登録した custom function / generic MEI PDU を含む
  pymodbus TCP / RTU / ASCII 双方向 interoperability test
- libmodbus TCP / RTU 双方向 interoperability test
- pinned pymodbus と system libmodbus peer を実行する独立した CI interoperability job

対象 runtime は AtomVM の `release-0.7` branch です。実機検証の baseline は
`v0.7.0-beta.0+git.8d3e051` で、runtime dependency はありません。
