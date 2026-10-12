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
| 2026-10-10 | soak harness の ExUnit 60 秒 timeout を除去し、RTU / ASCII / TCP combined 10 分 baseline を確認 |
| 2026-10-10 | 2 台の XIAO ESP32-C5 / HW-519 で real RS485 RTU 5 分 device baseline を確認 |
| 2026-10-10 | ESP32-C5 の TCP hard-limit probe が recoverable error より先に AtomVM runtime failure に至ることを切り分け、roadmap item を未完了のまま blocker を記録 |
| 2026-10-10 | bounded TCP probe cleanup の event-queue warning を AtomVM ESP32 socket driver の bounded queue backpressure と特定し、AVModbus resource leak ではないことを確認 |
| 2026-10-11 | RTU / ASCII / TCP combined host soak を 1 時間実行し、steady-state warm-up を追加した高負荷 run で memory bound と process-count recovery を確認 |
| 2026-10-11 | pymodbus 3.15.0 と RTU / ASCII broadcast、diagnostics、event log、device identification の external interoperability を追加検証 |
| 2026-10-11 | ESP32-C5 TCP hard-limit blocker の環境、bounded control、failure mode、安全な再現条件を AtomVM upstream 向け report に整理 |
| 2026-10-11 | XIAO ESP32-C5 / HW-519 の 20-step real-RS485 workflow probe を追加し、echo なし、20 ms gap、100 ms broadcast turnaround で 3 cycle / 60 request を確認 |
| 2026-10-11 | 通常 RTU client / server に compile-time gap override を追加し、20 ms gap の normal client で rapid polling 86 request / failure 0 を実機確認 |
| 2026-10-11 | retained TCP resource probe を実機確認済みの 1..4 connections に制限し、危険な hard-limit configuration を socket open 前に拒否 |
| 2026-10-11 | Linux subprocess の real `:emfile` を再現し、TCP client reconnect と TCP server restart の capacity recovery test を追加 |
| 2026-10-11 | AtomVM target を `release-0.7` と明確化し、head `1f372559` まで socket / timer hard-limit path に変更がないことを監査 |
| 2026-10-11 | 通常の実機 compatibility test を公式 `v0.7.0-beta.0` image に固定し、source build を matching symbol が必要な upstream crash diagnostic に限定 |
| 2026-10-11 | 利用可能な hardware に合わせ、USB-RS485 adapter / commercial device を completion criteria から外し、real bus は 2 台の XIAO / HW-519、independent peer は pymodbus / libmodbus で検証する scope に確定 |
| 2026-10-11 | resource exhaustion item を、host の real `:emfile` recovery、AtomVM の bounded device recovery、現行公式 runtime の hard-limit failure という supported boundary で解決。runtime path 更新時の再評価条件を記録 |
| 2026-10-12 | AtomVM UART の read 間で発生する byte loss を専用 reader と bounded broker で解消し、実 RS485 の ASCII 7E1 / RTU workflow で確認 |
| 2026-10-12 | Serial Transport contract、instance ごとの UART 設定と speed-based RTU timing、256-byte RTU response 上限を追加 |
| 2026-10-13 | UART RX idle drain を Modbus silence から分離。即時転送と 3 ms では実機で byte 欠落、20 ms では RTU 3 cycle / 60 request 完走を確認し、reader failure propagation と broker host tests を追加 |
| 2026-10-13 | Serial Client を non-blocking coordinator + single transaction worker に変更し、既定 64 件の bounded queue、`:queue_full`、failure drain を追加 |
| 2026-10-13 | Serial / TCP の async request を synchronous admission に変更し、queue overflow を直接返却。deadline arbiter を受付済み request に限定し、mailbox / helper process の backpressure を強化 |
| 2026-10-13 | async admission 後の production artifact は 139,600 bytes。AtomVM compatibility check を通過し、139,800-byte budget へ更新 |
| 2026-10-13 | 更新した TCP resource probe を ESP32-C5 で 3 cycle 実行。process は各 cycle `4 -> 57 -> 4` に回復し、`result=ok`。続けて RTU workflow 3 cycle / 60 request も成功し Client board を workflow image に復元 |
| 2026-10-13 | official AtomVM `v0.7.0-beta.0` tag が実機 revision と同じ `8d3e051` であることを確認。codec 最適化は bottleneck の実測がないため見送り、runtime 更新・実測時の release gate として整理 |

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
- host soak harness の combined 10 分実行（1 ms interval）で RTU 299,222、ASCII 299,208、
  TCP 298,507 iteration が成功。process count は 126 のまま、最大 memory growth は RTU server の
  1,872 bytes で、設定した 4,096-byte bound 内
- combined host soak を 1 ms interval で 1 時間完走し、request correctness と process count 126 → 126 を維持。
  cold baseline との比較では RTU server が 3,976 → 8,864 bytes となったため、bounded 64-entry serial
  event log を 128 verified iteration で満たしてから baseline を取るよう harness を修正。0 ms interval の
  5 分 accelerated run は RTU 5,225,194、ASCII 5,249,427、TCP 3,099,286 iteration、process count
  126 → 126 で成功し、RTU / ASCII server memory はともに 8,864 → 5,848 bytes。unbounded growth ではなく
  cold-to-steady-state measurement artifact だったことを確認
- XIAO ESP32-C5 の RTU server で 1 秒間隔の health telemetry を 10 回連続取得。warm-up 後は
  free heap 148,032 bytes、process count 7、memory process 576 bytes、server process 940 bytes、
  両 mailbox length 0 で安定し、全 snapshot で `status=:connected`
- XIAO ESP32-C5 / HW-519 の real RS485 RTU を 100 ms interval で 5 分実行し、1,623 request 成功、
  failure 0。client 29 回 / server 32 回の health snapshot はすべて `status=:connected`、mailbox 0 で、
  warm-up 後の free heap と managed process memory は安定
- periodic telemetry 追加後の default production `sample_app.avm` は 123,404 bytes、
  SHA-256 は `76069e17d3064c4bb2cc614947effe302c1c12d6e341abae53f5a4ab5994fb45`、
  126,000-byte budget 内
- bounded TCP queue 追加後の default production `sample_app.avm` は 124,312 bytes、
  SHA-256 は `80efcdb861f6ec40949327ac0f257f6eca8f69cae559576d8cdb4230dd5e6abd`、
  126,000-byte budget 内
- property suite を各 property 2,000 case で実行して成功
- pymodbus peer と TCP の read / write / exception / device identification を双方向確認
- pymodbus peer と RTU / ASCII の read / write / exception / device identification を双方向確認
- pymodbus peer と RTU / ASCII diagnostics echo を双方向確認。pymodbus client → AVModbus server では
  bus message counter、communication event counter / log、basic device identification を decode し、
  unit `0` broadcast write が response なしで holding register `40` を `4242` に更新することを確認。
  逆方向の broadcast は pymodbus server が unit `0` を unit `1` datastore に展開しない peer limitation のため、
  diagnostics と device identification のみを reciprocal coverage とした
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
- installed firmware `0.7.0-beta.0+git.8d3e051` に含まれる warning 文字列と AtomVM ESP32
  `socket_driver.c` を照合し、cleanup warning は lwIP callback を 32-entry `netconn_events` queue と
  16-entry global `event_queue` へ通知する platform path の queue backpressure と特定。warning を挟んでも
  probe は 3 cycle 連続で process count と free heap の recovery 判定に成功しており、AVModbus resource leak
  の証拠ではない。AtomVM runtime 更新時の再評価対象として tracking を完了
- compatibility fix 後の default production `sample_app.avm` は 126,020 bytes、SHA-256 は
  `ee7c4f5fb6cacdd0595ac52fe13a19bf13bf28b04463e25fc61516ab540ff8ae`。
  intentional 140-byte increase として regression budget を 126,200 bytes に更新し、180 bytes の headroom を維持
- compatibility fix 後も pymodbus 3.15.0 / libmodbus 3.1.11 を含む external suite は
  200 tests / 6 properties が成功
- default production artifact を XIAO ESP32-C5 に復元し、12 秒 monitor で正常 boot と
  RTU client の連続 2 回の `:timeout` 後の継続動作を確認
- TCP hard-limit 検証で managed client 8 個を同時に起動すると、AtomVM timer manager の 5 秒 call timeout 後に
  application が終了した。接続を逐次化した managed client probe と raw loopback socket probe でも
  recoverable な `:emfile` / `:enfile` / `:enobufs` / `:enomem` / `:system_limit` は観測できず、raw probe は
  ESP-IDF の `abort()` (`PC 0x4201fa15`) に至った。危険な diagnostic mode は repository に残さず、
  AtomVM runtime 側を symbol 付き build で調査できるまで hard-limit roadmap item は未完了とする。
  環境、known-good control、failure mode と安全な再調査手順は
  [`../ATOMVM_TCP_HARD_LIMIT.md`](../ATOMVM_TCP_HARD_LIMIT.md) に整理
- XIAO ESP32-C5 / HW-519 の real RS485 で compile-time workflow probe を実行。write-single response の
  request echo 特性と read-back を組み合わせて local adapter echo なしと分類し、register / coil、mask write、
  read-write multiple、file record、FIFO、diagnostics、device identification、broadcast、exception response の
  20 step を検証。calculated 5 ms gap は第 2 cycle、10 ms は第 3 cycle に timeout が再現したが、20 ms は
  3 cycle / 60 request が成功。UART API 境界の最小 response-to-next-write は 37 ms、100 ms broadcast
  turnaround の request elapsed は 130 ms で、直後の read も更新値を返した。waveform 計測とは区別する
- workflow probe は compile-time opt-in のため、default production `sample_app.avm` は 126,012 bytes、
  SHA-256 は `e5399b923a9730f2bc98ec0f44634e0f683b49b87c8c36a065f6930fbc87a1cb` で、
  126,200-byte budget 内に 188 bytes の headroom を維持
- workflow で確認した hardware margin を通常 application に適用できるよう、`MODBUS_RTU_GAP_MS` から
  client / server 共通の compile-time default gap を設定可能にした。`0` は従来どおり baud rate から算出し、
  explicit `gap:` option は引き続き優先する。20 ms override と request interval 0 ms の normal client を
  10 秒 monitor し、real RS485 function `0x03` は 86 response、failure 0
- retained resource probe に 1..4 connections の fail-closed guard を追加。5 connections の host run は
  ESP32 固有 API や socket を呼ぶ前に `unsafe_connection_count` を返した。4 connections の実機 regression は
  3 cycle とも process count 4 -> 27 -> 4 に回復し、cycle 1 の free heap は
  136,508 -> 117,176 -> 135,936 bytes、cycle 2 は 135,772 -> 116,464 -> 135,220 bytes、cycle 3 は
  135,064 -> 116,440 -> 135,192 bytes、最終 result は `ok`。その後 normal RTU server を復元
- Linux subprocess の file-descriptor soft limit を 64 に下げ、loopback listener で実際の `:emfile` を発生。
  managed TCP client は status に `{:disconnected, :emfile}` を保持し、descriptor を 8 個解放すると再接続して
  holding register request に成功。TCP server startup も exhaustion 中は `{:error, :emfile}`、解放後は
  `{:listening, 0}` で正常起動することを確認。AtomVM は error return 前に runtime failure となるため未完了のまま
- AtomVM `release-0.7` head `1f372559`（2026-10-04）を installed firmware commit `8d3e051` と比較。
  間の 4 commit は version metadata と MAP_EXT key order の修正だけで、ESP32 socket driver、event queue、
  timer manager、scheduler timer path は同一。beta.0 release asset は ESP32-C5 image / checksum のみで
  ELF / map を含まないため、symbol 付き source build なしに abort PC を確実に解決できないことを確認
- 実 RS485 の ASCII 7E1 workflow で 32-byte UART chunk をまたぐ Function `0x17` request の tail が
  欠落することを再現。serial server が partial frame を即時に読み進めるよう修正し、さらに専用 reader が
  `uart:read/2` を継続する bounded UART broker を追加。ASCII は 20 ms gap で 3 cycle / 60 request を
  2 回連続完走し、最小 response-to-next-write 36 ms、broadcast turnaround 130 ms。RTU も同条件で
  3 cycle / 60 request を完走し、最小 gap 37 ms、turnaround 129 ms
- UART broker / reader 追加後の startup free heap delta は RTU client 22,976 bytes（process 3 → 7）、
  RTU server 32,408 bytes（process 3 → 8）。default production `sample_app.avm` は 129,064 bytes、
  SHA-256 は `57dfcbbaeb3183f716213ec4e9f1e6d8c8189d2f7030a9ef74fa17b2ec27d41f`。budget を
  129,250 bytes に更新し、186 bytes の headroom を維持
- Serial Transport / instance UART config / bounded RTU feed 追加後の default production
  `sample_app.avm` は 134,676 bytes、SHA-256 は
  `6db4a70bb7f32ccb850c56d22d445486e418a43e058fc4f3044bff6873851056`。budget を
  134,860 bytes に更新し、184 bytes の headroom を維持
- 同実装の startup free heap delta は RTU client 25,704 bytes（process 3 → 7、client 824 bytes）、
  RTU server 35,200 bytes（process 3 → 8、memory 560 bytes、server 1,204 bytes）。instance `serial:`
  configuration を使う実機 RTU / ASCII workflow はそれぞれ 3 cycle / 60 request を完走。RTU は最小 gap
  37 ms / broadcast 129 ms、ASCII 7E1 は最小 gap 36 ms / broadcast 131 ms
- 同変更後の pymodbus TCP / RTU / ASCII 双方向 interoperability suite は 209 tests / 6 properties、
  failure 0。両 XIAO は最終的に通常の RTU server / client image へ復元し、連続 read を確認
- Client / Server startup を必須の `transport:` option に統一し、TCP Client の接続先を `host:` に分離。
  Server の facade / transport-specific startup はすべて raw PID を返し、managed lifecycle は `stop/1` に統一。
  host suite 195 tests / 6 properties と pymodbus suite 209 tests / 6 properties、AtomVM compatibility check が
  failure 0。新 API で build した Client を実機へ書き込み、既存 Server から 3 回連続 read を確認。
  raw PID API へ更新した Server も実機へ書き込み、同じ Client から連続 read を確認。
  default production `sample_app.avm` は 133,600 bytes、SHA-256 は
  `9cee9eeaa12776ce788c514149cd2e331b7dbeb8860b4b38e5f4855f934e344c`
- Client request API を keyword options に統一し、positional timeout と async recipient を削除。
  host suite 195 tests / 6 properties と pymodbus suite 209 tests / 6 properties、ExDoc、AtomVM
  compatibility check は failure 0。更新した Client を XIAO ESP32-C5 に書き込み、接続済み Server から
  3 回連続で Holding Register を読めることを確認。default production `sample_app.avm` は 133,628 bytes、
  SHA-256 は `dcba14b0f49e58e46cd86da0b01d6acd231a3879055136304dab9fc1e93b0e4a`、
  134,860-byte budget まで 1,232 bytes
- 初期 Function `0x03` 実験用の未使用 PDU helper を削除し、device identification helper の category を
  `category:` option（既定 `:basic`）へ統一。host suite 196 tests / 6 properties、pymodbus suite
  210 tests / 6 properties、ExDoc、AtomVM compatibility check は failure 0。更新した Client を実機へ
  書き込み、接続済み Server から 3 回連続 read を確認。default production `sample_app.avm` は
  133,700 bytes、SHA-256 は `35b9feaa92530cb8a04ad85ac992c97b9a6f1ce779a58152eb70520366ca175b`、
  134,860-byte budget まで 1,160 bytes
- Serial Transport の startup callback を instance 設定を受け取る `open/1` に統一し、`open/0`
  compatibility fallback を削除。host coverage gate 81.08%、pymodbus suite 210 tests / 6 properties、
  ExDoc、AtomVM compatibility check は failure 0。更新した Client を実機へ書き込み、接続済み Server
  から 4 回連続 read を確認。default production `sample_app.avm` は 133,636 bytes、SHA-256 は
  `b541be2f634900fde08471e55c4168284a55ae3267b8ca7663873732cfcf73d8`、
  134,860-byte budget まで 1,224 bytes
- reader monitor、UART adapter host tests、instance RX idle timeout 追加後の default production
  `sample_app.avm` は 135,152 bytes、SHA-256 は
  `91ae3116914314626be15b817700be9e6b1fc768ca41b0993c48b63f62e66f73`。
  135,320-byte budget まで 168 bytes
- bounded Serial Client queue 追加後は host 207 tests / 6 properties、pymodbus suite 221 tests / 6
  properties、5 秒 combined soak が成功し、process count は 126 → 126。実 RS485 workflow も
  3 cycle / 60 request を完走した。
  default production `sample_app.avm` は 139,304 bytes、SHA-256 は
  `dcc738627d9605846c5b9c8bfc1cd6393bba11acdcc5564c940fed3f44b2e612`、
  139,500-byte budget まで 196 bytes
- UART broker の terminal error を buffered / delayed data より優先し、buffer を破棄して最初の failure
  reason を保持するよう修正。buffered data 後の failure、pending read 中の reader crash、timeout / failure、
  broker / owner 終了、managed Client reopen を deterministic host test で確認
- XIAO ESP32-C5 / HW-519、RTU 8N1、20 ms transmit gap で RX idle timeout を比較。9,600 baud / 20 ms と
  115,200 baud / 20 ms はそれぞれ 3 cycle / 60 request を完走し、request min / average / max は
  136 / 179 / 233 ms と 134 / 144 / 164 ms。9,600 baud / 10 ms は 5 request 目の
  `write_multiple_registers` で timeout したため、既定 20 ms を維持
- terminal error precedence 追加後の default production `sample_app.avm` は 139,660 bytes、SHA-256 は
  `caf14c2fedee928f86721ee3084d2aa00ee22c1b8eeb592f9a1e60b9e1eaf41c`。139,860-byte budget まで
  200 bytes の headroom を維持
