# 作業記録

細かな実装履歴は Git history に残し、このディレクトリでは主要マイルストーンだけを記録します。

| 日付 | 主な進展 |
| --- | --- |
| 2026-10-07 | Modbus core を `hello_atomvm_serial` から分離。PDU / RTU / CRC16、主要 client functions、transaction deadline、serial bus serialization を実装 |
| 2026-10-08 | project identity を `avmodbus` に統一。server core、sparse memory model、RTU server、broadcast、diagnostics、handler isolation、authorization、UART reconnect を実装 |
| 2026-10-09 | RTU transmit gap、client reconnect、async request、Modbus ASCII framing、managed ASCII client / server を実装 |
| 2026-10-09 | Modbus TCP の MBAP codec と fragmented / concatenated stream handling を実装 |
| 2026-10-09 | managed Modbus TCP client、並行 transaction matching、deadline、half-open detection、reconnect を実装 |
| 2026-10-09 | managed Modbus TCP server、connection concurrency、fair eviction、allowlist、idle policy を実装 |
| 2026-10-09 | PDU round-trip、任意 byte、stream 分割、稼働中 TCP client / server の property tests を追加 |
| 2026-10-09 | pymodbus 3.15.0 と Modbus TCP client / server の双方向 interoperability を確認 |
| 2026-10-09 | client / handler result contract、exception、invalid response error を統一 |
| 2026-10-09 | 253-byte PDU と TCP / RTU / ASCII maximum ADU の境界 test を追加 |
| 2026-10-09 | ExDoc configuration、Hex package manifest、CHANGELOG を整備 |
| 2026-10-09 | managed client の child specification、raw PID / name API、supervisor restart を実装 |
| 2026-10-09 | RTU / ASCII / TCP server の supervision、raw PID / name、stop API を統一 |
| 2026-10-09 | startup option、handler、name validation の tagged error contract を統一 |
| 2026-10-09 | idempotent read 限定 retry、bounded backoff、TCP reconnect integration test を追加 |
| 2026-10-09 | libmodbus 3.1.11 と TCP client / server の双方向 interoperability を確認 |
| 2026-10-09 | managed TCP client / server の IPv6 literal support と loopback integration test を追加 |
| 2026-10-09 | `AVModbus.Server` の統一 transport routing / supervision facade を追加 |
| 2026-10-09 | client の per-request keyword options と安全な read retry routing を追加 |
| 2026-10-09 | Modbus V1.1b3 の application / malformed conformance vectors を統合 |
| 2026-10-09 | AtomVM TLS capability boundary を監査し、Modbus/TCP Security を fail closed に固定 |
| 2026-10-09 | test-only PTY transport で pymodbus RTU / ASCII の双方向 interoperability を確認 |
| 2026-10-09 | roadmap を protocol coverage、実機 interoperability、hardening、resource 検証に再編し、Hex 公開を scope 外とした |
| 2026-10-09 | test-only PTY transport で libmodbus 3.1.11 RTU の双方向 interoperability を確認 |
| 2026-10-09 | TCP peer の FIN half-close / RST で pending / queued request を一度だけ失敗させ、再接続する regression tests を追加 |
| 2026-10-09 | RTU / ASCII server が noise、checksum error、fragmentation、128-frame burst 後も同期を維持する stress tests を追加 |
| 2026-10-09 | 8 concurrent TCP clients、各 24 pipelined requests、slow handler を組み合わせた load test を追加 |
| 2026-10-09 | serial client が repeated timeout / CRC error と 2 回の UART disconnect / reopen 後も transaction を継続する stress test を追加 |
| 2026-10-09 | pymodbus registered PDU と custom function / generic MEI を TCP / RTU / ASCII で双方向確認 |
| 2026-10-09 | serial deadline arbiter と serial / TCP accepted-request lifecycle stress test を追加 |
| 2026-10-09 | production example の AVM artifact size check と 126,000-byte regression budget を追加 |
| 2026-10-09 | XIAO ESP32-C5 で RTU client / server の free heap delta と process memory baseline を計測 |
| 2026-10-09 | RTU / ASCII / TCP の configurable host soak harness を追加し、combined 20 秒 baseline を確認 |
| 2026-10-09 | XIAO ESP32-C5 の device soak 向け periodic health telemetry を実装し、RTU server で実機確認 |
| 2026-10-09 | TCP client の未送信 queue に `max_queue` 上限と `:queue_full` recovery contract を追加 |
| 2026-10-09 | serial / TCP client に startup `timeout:` default と request 単位 override を追加 |
| 2026-10-09 | client-wide default timeout 版を XIAO ESP32-C5 に flash し、RTU timeout loop を実機確認 |
| 2026-10-09 | UART hardware configuration boundary を確定し、初期比較用 parity guide を役目完了として削除 |
| 2026-10-09 | zero-timeout serial probe の clock-tick race を修正し、即時 attempt contract を固定 |
| 2026-10-09 | XIAO ESP32-C5 用の bounded TCP resource recovery probe を追加し、AtomVM 非対応の `Map.pop/2` を TCP runtime path から除去 |

## 現在の検証状況

- protocol / transport behavior は host tests で継続検証
- Seeed Studio XIAO ESP32-C5 で AtomVM application の build / flash / boot を確認
- ESP32-C5 上で managed Modbus TCP listener の port 502 startup を確認
- unified result contract 版を ESP32-C5 に再 flash。`sample_app.avm` は 113,788 bytes、
  SHA-256 は `808434eb61c84bb6dc82b16e186a77a7da12b3a463658f386eed3ef6f8dd88ce`
- managed client supervision 版を ESP32-C5 に再 flash。`sample_app.avm` は 115,136 bytes、
  SHA-256 は `ba8489cb2e752a0c195b581a6cfed186f070cb379657619883bd7bc7e2ca9a5d`
- managed server supervision 版を ESP32-C5 に再 flash。`sample_app.avm` は 117,848 bytes、
  SHA-256 は `27fce8117c240c533490be1638332cfbca25a7964a5af8dce42363bac008347c`
- startup validation contract 版を ESP32-C5 に再 flash。`sample_app.avm` は 118,192 bytes、
  SHA-256 は `94b0f9805b8196be8b5671771172ed1f2fb7ebb1d7272a537527de56c0ce6152`
- idempotent read retry 版を ESP32-C5 に再 flash。`sample_app.avm` は 119,760 bytes、
  SHA-256 は `88a4d30a1116c8b0452615dd0ea1779c26d068411ba4bff2bc4bd8db633e0661`
- IPv6 literal support 版を ESP32-C5 に再 flash。`sample_app.avm` は 120,024 bytes、
  SHA-256 は `b663e1cbe86dc313148201bcc93d489947474f35e7365598c17fb127147c4fc4`
- unified server startup facade 版を ESP32-C5 に再 flash。`sample_app.avm` は 121,884 bytes、
  SHA-256 は `ab640c6290016166ee341d045d574596373d7357c1832be31986207a4a8dc7be`
- per-request keyword option 版を ESP32-C5 に再 flash。`sample_app.avm` は 122,592 bytes、
  SHA-256 は `aabea2161e426a324bb5b5d4743981bdd539ccf9324fcdef793614cab23c0318`
- fail-closed TLS boundary 版を ESP32-C5 に再 flash。`sample_app.avm` は 123,052 bytes、
  SHA-256 は `274479fed499d4a82632e3bd49948c248f1bd5a08312341bda65050081c5d8ec`
- serial deadline arbiter 版を AtomVM production build。`sample_app.avm` は 123,140 bytes、
  SHA-256 は `1731e2346dd50b99c5cb6a2a5a12d474572cd98565b87d364185b7415ef7fa30`
- XIAO ESP32-C5 / RTU client は startup free heap delta 20,192 bytes、managed client process 628 bytes
- XIAO ESP32-C5 / RTU server は startup free heap delta 29,584 bytes、memory process 560 bytes、
  managed server process 1,024 bytes
- opt-in memory probe 追加後の default production `sample_app.avm` は 123,316 bytes、
  SHA-256 は `f5b17404de6add700e7cb915b1fd025cb41557c9f4c162b61a008a202e07a71c`、
  126,000-byte budget 内
- host soak harness の combined 20 秒実行で RTU 3,329、ASCII 3,328、TCP 3,322 iteration が成功。
  process count は 126 のまま、各 managed process の memory growth は設定した 4,096-byte bound 内
- XIAO ESP32-C5 の RTU server で 1 秒間隔の health telemetry を 10 回連続取得。warm-up 後は
  free heap 148,032 bytes、process count 7、memory process 576 bytes、server process 940 bytes、
  両 mailbox length 0 で安定し、全 snapshot で `status=:connected`
- periodic telemetry 追加後の default production `sample_app.avm` は 123,404 bytes、
  SHA-256 は `76069e17d3064c4bb2cc614947effe302c1c12d6e341abae53f5a4ab5994fb45`、
  126,000-byte budget 内
- bounded TCP queue 追加後の default production `sample_app.avm` は 124,312 bytes、
  SHA-256 は `80efcdb861f6ec40949327ac0f257f6eca8f69cae559576d8cdb4230dd5e6abd`、
  126,000-byte budget 内
- property suite を各 property 2,000 case で実行して成功
- pymodbus peer と TCP の read / write / exception / device identification を双方向確認
- pymodbus peer と RTU / ASCII の read / write / exception / device identification を双方向確認
- pymodbus peer と TCP / RTU / ASCII の custom function `0x41` / generic MEI `0x0D` を双方向確認
- libmodbus 3.1.11 peer と TCP / RTU の read / write / mask / read-write / exception を双方向確認
- pymodbus と libmodbus の全 interoperability tag を同時に有効化し、198 tests / 6 properties が成功
- client-wide default timeout 追加後の external suite は pymodbus 3.15.0 / libmodbus 3.1.11 を含む
  200 tests / 6 properties が成功
- request timing resolver の重複除去と zero-timeout race 修正後の default production
  `sample_app.avm` は 125,880 bytes、SHA-256 は
  `da6f995fef6c551b985a968d9d385ffed8e94b627e5e6d2987d1585ed74e684f`、126,000-byte budget 内
- 同 artifact を XIAO ESP32-C5 に flash。AtomVM `0.7.0-beta.0+git.8d3e051` で boot し、startup
  `timeout: 1_000` を使う RTU client が 10 秒の monitor 中に 2 回連続で `:timeout` を返して継続動作
- serial client test 33 件を異なる seed で 21 回連続実行し、zero-timeout probe を含めて failure なし
- opt-in TCP resource probe の `sample_app.avm` は 132,568 bytes、SHA-256 は
  `7147c518f71c55a2f48523537887fc84b2ddf1ec4846c3b74696078a076482ed`
- XIAO ESP32-C5 / AtomVM `0.7.0-beta.0+git.8d3e051` で、warm-up 後に 4 client、各 3 accepted request
  と 1 `:queue_full` を 3 cycle 実行。process count は各 cycle で 4 -> 27 -> 4 に回復し、free heap は
  cycle 1 が 136,088 -> 116,784 -> 135,532 bytes、cycle 2 が 135,368 -> 116,072 -> 134,808 bytes、
  cycle 3 が 134,652 -> 116,028 -> 134,772 bytes。largest free block は warm-up 後 86,016 bytes で安定
- 最初の device run で TCP response path の `Map.pop/2` が AtomVM では `undef` になることを検出。
  client response と server eviction を `Map.fetch/2` + `Map.delete/2` に置換し、同じ diagnostic artifact で
  `modbus_resource_probe result=ok cycles=3` を確認。socket cleanup 時の AtomVM event-queue warning は継続追跡
- compatibility fix 後の default production `sample_app.avm` は 126,020 bytes、SHA-256 は
  `ee7c4f5fb6cacdd0595ac52fe13a19bf13bf28b04463e25fc61516ab540ff8ae`。
  intentional 140-byte increase として regression budget を 126,200 bytes に更新し、180 bytes の headroom を維持
- compatibility fix 後も pymodbus 3.15.0 / libmodbus 3.1.11 を含む external suite は
  200 tests / 6 properties が成功
- default production artifact を XIAO ESP32-C5 に復元し、12 秒 monitor で正常 boot と
  RTU client の連続 2 回の `:timeout` 後の継続動作を確認
- real RS485 peer との interoperability test は未完了
