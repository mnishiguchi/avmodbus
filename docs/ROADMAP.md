# ロードマップ

## ゴール

AVModbus を、AtomVM application から単独で利用できる full-fledged Modbus package にします。
AtomVM が提供する機能の範囲で、完全な protocol coverage、client / server usability、
相互運用性、運用上の堅牢性を目指します。

このロードマップの完了条件は、Hex package として公開することではなく、次を満たすことです。

- 標準 Modbus function と exception response を一貫して扱える
- RTU / ASCII / TCP の client と server を supervision tree から安全に利用できる
- 実 RS485 bus と主要な外部 software implementation で相互運用できる
- timeout、破損 frame、切断、再接続、長時間運転に耐えられる
- AtomVM device 上で resource usage と artifact size を継続的に把握できる

## 現在地

- Modbus Application Protocol の全 public function、exception、custom function / MEI の low-level path を実装済み
- RTU / ASCII / TCP の codec、managed client、managed server を実装済み
- client / server の child specification、registered name、stop API、統一 server facade を実装済み
- result、exception、invalid response、startup validation の error contract を整備済み
- idempotent read 向けの opt-in retry と request 単位の synchronous / asynchronous option を実装済み
- serial / TCP client の request timeout を startup default と request 単位の override で設定可能
- TCP client の request queue、`max_pending`、transaction-id correlation、out-of-order response、FIN / RST recovery、reconnect / backoff を実装済み
- TCP server の connection limit / fair eviction、address allowlist、idle timeout、handler isolation を実装済み
- TCP server の concurrent connection、pipelined request、slow handler load coverage を整備済み
- serial の broadcast、adapter echo、diagnostic counter / event log、listen-only mode、UART reopen / backoff を実装済み
- serial client の repeated timeout、CRC error、disconnect / reopen recovery stress coverage を整備済み
- serial / TCP asynchronous request の deadline-bounded exactly-once result stress coverage を整備済み
- RTU / ASCII server の noise、CRC / LRC corruption、fragmented input、back-to-back frame stress coverage を整備済み
- coils、discrete inputs、holding / input registers、file records、FIFO の sparse memory handler を実装済み
- specification vectors、property tests、PDU / ADU 境界、malformed / fragmented / noisy stream の regression tests を整備済み
- `pymodbus` と TCP / RTU / ASCII、`libmodbus` と TCP / RTU の双方向 interoperability を確認済み
- `pymodbus` と RTU / ASCII の diagnostics echo を双方向、diagnostic counter / event log、
  device identification、broadcast write を pymodbus client → AVModbus server 方向で確認済み
- custom function と generic MEI を `pymodbus` の registered PDU と TCP / RTU / ASCII で双方向確認済み
- pinned production example に AVM artifact size の 126,200-byte regression budget を設定済み
- XIAO ESP32-C5 上で RTU client / server の free-heap delta と managed process memory baseline を計測済み
- RTU / ASCII / TCP client / server の configurable host soak harness と 10 分の combined baseline を整備済み
  - 1 ms interval で RTU 299,222、ASCII 299,208、TCP 298,507 iteration、process count 126 → 126、
    managed process memory growth は 4,096-byte bound 内
- RTU / ASCII / TCP client / server の 1 時間 combined host soak と高負荷 steady-state 検証を完了
  - 1 ms interval の 1 時間 run は request correctness と process-count bound を維持
  - bounded serial event log を warm-up 後、0 ms interval の 5 分 run で RTU 5,225,194、
    ASCII 5,249,427、TCP 3,099,286 iteration、process count 126 → 126、全 process memory bound 内
- XIAO ESP32-C5 の長時間検証向けに connection state / heap / process / mailbox の periodic telemetry を整備済み
- 2 台の XIAO ESP32-C5 / HW-519 の real RS485 で 5 分の RTU device baseline を確認済み
  - 100 ms polling で 1,623 request 成功、failure 0、全 health snapshot で connected / mailbox 0
- TCP client の未送信 queue を bounded にし、saturation error と capacity recovery を検証済み
- client-wide default timeout を XIAO ESP32-C5 の RTU client で起動・連続 timeout 確認済み
- XIAO ESP32-C5 上で bounded TCP socket / process / heap pressure と 3-cycle recovery を確認済み
- 2 台の XIAO ESP32-C5 と HW-519 automatic-direction RS485 transceiver で RTU function `0x03` を
  9,600 / 19,200 / 38,400 / 115,200 baud、8N1 で確認済み
- 9,600 baud の polling 中に実 RS485 `A` conductor を切断して timeout を確認し、再接続後は
  client / server を再起動せず連続 response に復帰することを確認済み
- XIAO ESP32-C5 / HW-519 の real RS485 で 20-step representative workflow を 3 cycle 完走し、
  local echo、request gap、broadcast turnaround を AtomVM UART API 境界で characterise 済み
- board 固有 UART 設定は application configuration、動的 UART ownership は injected transport に分離

今後は新しい API の追加より、fault recovery と resource usage の検証を優先します。

## 優先度 1: 実 serial / RS485 相互運用性

- [x] 9,600 / 19,200 / 38,400 / 115,200 baud での動作確認
- [x] automatic-direction RS485 transceiver での echo / turnaround / frame gap 確認
  - XIAO ESP32-C5 / HW-519、9,600 baud の real bus で local echo なしと分類
  - calculated 5 ms と 10 ms gap では rapid workflow 中の timeout を再現。20 ms では 3 cycle / 60 request 成功
  - UART API 境界の最小 response-to-next-write は 37 ms、configured 100 ms broadcast turnaround は 130 ms
    request elapsed で、その直後の read も成功。waveform 自体の計測ではないことを明記
  - 通常 client / server profile に compile-time `:modbus_rtu_gap_ms` override を追加し、20 ms / 0 ms polling
    の normal client で 10 秒間に 86 response、failure 0 を実 RS485 で確認
- [x] 実 RS485 cable の disconnect / reconnect と request recovery の確認
- [x] broadcast、diagnostics、device identification の外部 implementation との確認
  - pymodbus 3.15.0 の独立 process と PTY serial bridge を使い RTU / ASCII で確認
- [x] 実機要件に基づき、managed reopen を保つ runtime UART override の必要性を再評価
  - 現在の固定 board / wiring profile では追加せず、application configuration と injected transport を維持

## 優先度 2: AtomVM 実機と resource 検証

- [x] RTU / ASCII / TCP client / server の長時間 soak test
- [x] resource exhaustion 時の error / recovery behavior と runtime boundary を確認
  - [x] TCP client wait queue の saturation error と capacity recovery を host 上で確認
  - [x] Linux subprocess の real file-descriptor exhaustion と capacity recovery を確認
    - `ulimit -n 64` で client status `{:disconnected, :emfile}` と server startup
      `{:error, :emfile}` を確認し、descriptor release 後に reconnect / request / listener startup 成功
  - [x] AtomVM device 上で bounded socket / process / heap pressure と recovery を確認
    - retained probe は実機で回復確認済みの 1..4 connections だけを許可し、それ以外は socket open 前に
      fail closed。通常の実機 test は公式 `v0.7.0-beta.0` image に固定
  - [x] AtomVM device 上の hard-limit behavior と supported boundary を確定
    - 2026-10-10 の ESP32-C5 検証では、recoverable な socket error を返す前に AtomVM runtime が
      timer manager timeout または native abort に至ることを確認。現行 runtime では hard-limit recovery を
      AVModbus へ提供できない platform constraint とし、production probe は確認済みの 1..4 connections に制限。
      host では実 `:emfile` からの client / server recovery を確認済み。
      再現条件、control result、安全な再調査手順は
      [AtomVM ESP32-C5 TCP hard-limit report](ATOMVM_TCP_HARD_LIMIT.md) に整理
    - 2026-10-11 の target audit では `release-0.7` head `1f372559` と installed `8d3e051` の間に
      socket / event queue / timer runtime path の変更なし。公式 release asset に ELF / map もないため、
      該当 runtime path を更新した公式 image が公開された場合に再評価。source build は matching ELF / map が
      必要な upstream crash diagnostic にだけ使用し、現行公式 image の acceptance evidence とは扱わない
  - [x] loopback socket cleanup 時の AtomVM event-queue warning を追跡
    - AtomVM `0.7.0-beta.0+git.8d3e051` の ESP32 socket driver が socket callback を
      bounded FreeRTOS event queue へ enqueue できない場合の platform warning と特定
    - warning 発生後も 3 cycle すべてで AVModbus process / heap recovery は成功。library leak とは扱わず、
      AtomVM runtime 更新時に再評価
- [x] Seeed Studio XIAO ESP32-C5 上で representative workflow を継続検証
  - real RS485 で registers / coils、mask / combined read-write、file record、FIFO、diagnostics、
    device identification、broadcast、exception response の 20-step workflow を 3 cycle 完走

## AtomVM platform に依存する制約

Modbus/TCP Security は mutual-authenticated TLS が必要です。現在対象としている AtomVM runtime では必要な TLS client / server API が揃っていないため、TLS option は fail closed とし、silent downgrade は行いません。詳細は [ADR 0015](adr/0015-fail-closed-without-mutual-tls.md) を参照してください。

AtomVM が必要な TLS API を提供した時点で、Modbus/TCP Security を supported scope に追加します。

## 現時点で対象外

- Hex package としての公開および Hex release workflow
- USB-RS485 adapter / commercial Modbus device との electrical interoperability
- RTU-over-TCP など標準外 transport
- test adapter を除く AtomVM 以外の runtime 向け transport adapter
