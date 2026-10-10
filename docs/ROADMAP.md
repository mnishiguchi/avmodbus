# ロードマップ

## ゴール

AVModbus を、AtomVM application から単独で利用できる full-fledged Modbus package にします。
AtomVM が提供する機能の範囲で、完全な protocol coverage、client / server usability、
相互運用性、運用上の堅牢性を目指します。

このロードマップの完了条件は、Hex package として公開することではなく、次を満たすことです。

- 標準 Modbus function と exception response を一貫して扱える
- RTU / ASCII / TCP の client と server を supervision tree から安全に利用できる
- 実際の Modbus device および主要な外部 implementation と相互運用できる
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
- custom function と generic MEI を `pymodbus` の registered PDU と TCP / RTU / ASCII で双方向確認済み
- pinned production example に AVM artifact size の 126,200-byte regression budget を設定済み
- XIAO ESP32-C5 上で RTU client / server の free-heap delta と managed process memory baseline を計測済み
- RTU / ASCII / TCP client / server の configurable host soak harness と 10 分の combined baseline を整備済み
  - 1 ms interval で RTU 299,222、ASCII 299,208、TCP 298,507 iteration、process count 126 → 126、
    managed process memory growth は 4,096-byte bound 内
- XIAO ESP32-C5 の長時間検証向けに connection state / heap / process / mailbox の periodic telemetry を整備済み
- TCP client の未送信 queue を bounded にし、saturation error と capacity recovery を検証済み
- client-wide default timeout を XIAO ESP32-C5 の RTU client で起動・連続 timeout 確認済み
- XIAO ESP32-C5 上で bounded TCP socket / process / heap pressure と 3-cycle recovery を確認済み
- 2 台の XIAO ESP32-C5 と HW-519 automatic-direction RS485 transceiver で RTU function `0x03` を
  9,600 / 19,200 / 38,400 / 115,200 baud、8N1 で確認済み
- 9,600 baud の polling 中に実 RS485 `A` conductor を切断して timeout を確認し、再接続後は
  client / server を再起動せず連続 response に復帰することを確認済み
- board 固有 UART 設定は application configuration、動的 UART ownership は injected transport に分離

今後は新しい API の追加より、実 device での相互運用性、fault recovery、resource usage の検証を優先します。

## 優先度 1: 実 serial / RS485 相互運用性

- [ ] USB-RS485 adapter と実 Modbus device を使った client / server 動作確認
- [x] 9,600 / 19,200 / 38,400 / 115,200 baud での動作確認
- [ ] automatic-direction RS485 transceiver での echo / turnaround / frame gap 確認
- [x] 実 RS485 cable の disconnect / reconnect と request recovery の確認
- [ ] broadcast、diagnostics、device identification の外部 implementation との確認
- [x] 実機要件に基づき、managed reopen を保つ runtime UART override の必要性を再評価
  - 現在の固定 board / wiring profile では追加せず、application configuration と injected transport を維持

## 優先度 2: AtomVM 実機と resource 検証

- [ ] RTU / ASCII / TCP client / server の長時間 soak test
- [ ] resource exhaustion 時の error と recovery behavior を確認
  - [x] TCP client wait queue の saturation error と capacity recovery を host 上で確認
  - [x] AtomVM device 上で bounded socket / process / heap pressure と recovery を確認
  - [ ] AtomVM device 上で hard-limit exhaustion error と recovery を確認
  - [ ] loopback socket cleanup 時の AtomVM event-queue warning を追跡
- [ ] Seeed Studio XIAO ESP32-C5 上で representative workflow を継続検証

## AtomVM platform に依存する制約

Modbus/TCP Security は mutual-authenticated TLS が必要です。現在対象としている AtomVM runtime では必要な TLS client / server API が揃っていないため、TLS option は fail closed とし、silent downgrade は行いません。詳細は [ADR 0015](adr/0015-fail-closed-without-mutual-tls.md) を参照してください。

AtomVM が必要な TLS API を提供した時点で、Modbus/TCP Security を supported scope に追加します。

## 現時点で対象外

- Hex package としての公開および Hex release workflow
- RTU-over-TCP など標準外 transport
- test adapter を除く AtomVM 以外の runtime 向け transport adapter
