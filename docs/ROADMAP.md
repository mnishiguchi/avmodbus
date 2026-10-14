# ロードマップ

AVModbus は、AtomVM で Modbus RTU / ASCII / TCP の Client と Server を提供します。
主要機能と当初予定した検証は完了しており、現在は 1.0 前の API 整理と安定性の向上を優先します。
Hex package としての公開は完了条件に含めません。

## 完了した範囲

- Modbus Application Protocol の public Function Code、exception、custom function / MEI
- RTU / ASCII / TCP の codec、managed Client、managed Server
- broadcast、diagnostics、device identification、sparse memory handler
- supervision、起動時の設定チェック、timeout、読み取り限定 retry、再接続
- TCP の並行 request、bounded queue、connection 制限、allowlist、idle timeout
- malformed frame、切断、再接続、負荷、property、soak test
- `pymodbus` / `libmodbus` との双方向 interoperability test
- XIAO ESP32-C5 / HW-519 による実 RS485 通信と切断復旧
- AtomVM 実機での memory、artifact size、bounded resource pressure の計測

詳細な設計は [Architecture](ARCHITECTURE.md)、検証履歴は [Worklog](worklog/README.md) を参照してください。
測定値は [Memory footprint](MEMORY_FOOTPRINT.md) と [Artifact size](ARTIFACT_SIZE.md) に集約しています。

## 次の改善

### Phase 1: UART の timing と lifecycle

- [x] Modbus silence と UART RX idle drain を分離し、実機で安全な値を確認する
- [x] broker が reader の終了を検知し、待機中の read と Client / Server へ失敗を伝える
- [x] terminal error を buffered / delayed data より優先し、最初の failure reason を保持する
- [x] `modbus_rtu_gap_ms` を計算値の下限として扱い、境界値をテストする
- [x] managed transport と injected transport の ownership を API と文書で一致させる
- [x] data / timeout / cancel / overflow / owner・reader 終了と Client reopen の broker test を通常の BEAM で実行する

### Phase 2: compatibility と bounded resource

- [x] Modbus ASCII で予約済み Unit ID `248..255` を拒否する
- [x] Modbus RTU decode でも予約済み Unit ID `248..255` を拒否し、encode / typespec と一致させる
- [x] CI で AtomVM compatibility check と `.avm` package 作成を実行する
- [x] Serial Client の async request queue に上限と overflow policy を設ける
- [x] TCP Server の socket owner を slow handler から分離し、connection ごとの receive buffer を制限する
- [x] slow handler、pipelined request、receive overflow の deterministic host test を追加する
- [x] TCP connection 終了時に実行中の isolated handler を停止し、orphan process を残さない
- [x] `trap_exit` handler の切断、overflow、eviction、server stop と反復 overload recovery を回帰テストする
- [x] TCP `max_buffer` が broker の未配送 data だけを制限することを明文化する
- [x] ESP32-C5 で 1..4 loopback connections の idle / active resource snapshot と cleanup を比較する
- [x] socket handoff 前の shutdown / eviction と handoff failure cleanup を回帰テストする
- [x] forced broker death 時も listener が `trap_exit` handler を cleanup する ownership を固定する
- [x] 応答不能な複数 broker に対する shutdown / eviction の待機時間を共有 deadline で制限する
- [x] slow-handler burst 中の broker / worker mailbox、memory、heap の sampled maximum を host で計測する
- [x] queue と recovery の変更後に property / stress / soak test を再実行する

### Phase 3: release 前の確認

- [x] public API と error tuple を確認し、async admission、Unit ID、ownership、queue error の契約を明文化する
- [x] official AtomVM `v0.7.0-beta.0` (`8d3e051`) で compile、package、TCP resource probe、
  実 RS485 smoke test を再実行する
- [x] RX idle timeout と baud rate の latency を実機で比較し、20 ms の安定性を再確認する
- [x] pinned pymodbus と system libmodbus の interoperability test を独立した CI job にする
- [x] codec / allocation の最適化は現在の実機・soak test に bottleneck の証拠がないため見送る

module 分割は目的にせず、責務の変更や決定的な test の追加に必要な場合だけ行います。

## 継続中の安定化チェック

- [x] slow broker eviction 中に request を待機させ、後続の handler 登録・応答・cleanup を host でテストする
- [x] interoperability CI を固定 seed 2 種類で反復実行する設定を追加する（CI 通過実績は別途確認）
- [x] external peer の prerequisite / build failure を invalid test ではなく CI failure にする
- [x] AtomVM TCP resource probe のログを build / runtime / device 別の CSV に変換する host tool を追加する
- [x] [実機互換性表](COMPATIBILITY_MATRIX.md)と[リリース前 checklist](RELEASE_CANDIDATE_CHECKLIST.md)を整備する
- [ ] GitHub Actions で新しい CI job の通過と再現性を確認する
- [ ] 利用可能な別の hardware / runtime で追加検証し、確認済み構成を更新する

## 継続的な release gate

- official AtomVM `release-0.7` image を更新した場合は、CI の 3 build variant、artifact size、
  TCP resource probe、実 RS485 workflow を再実行する
- ESP32-C5 上の CPU、GC、free heap 計測で codec が bottleneck と確認できた場合だけ、CRC / ASCII の
  allocation 最適化を再検討する
- public API を変更する場合は、同期戻り値、async admission、error tuple、ownership を同時に更新する
- `uart_rx_idle_timeout_ms` を短縮する場合は、長い frame を含む 60-request workflow を複数 baud rate で
  完走し、timeout / CRC error が増えず、latency 改善が再現することを条件とする

## Platform に依存する制約

### Modbus/TCP Security

対象 AtomVM runtime は相互認証 TLS に必要な Client / Server API を提供していません。
TLS option は `{:error, :tls_not_supported}` を返し、暗号化なしへ切り替わりません。
必要な API が揃った時点で再評価します。詳細は [ADR 0015](adr/0015-fail-closed-without-mutual-tls.md) を参照してください。

### ESP32-C5 の TCP resource 上限

確認済み範囲を超える socket pressure では、回復可能な error が Elixir に返る前に AtomVM runtime が
応答を失う場合があります。通常の probe は安全確認済みの範囲に制限しています。
該当 runtime path が更新された公式 image が公開された場合に再評価します。
詳細は [TCP リソース上限レポート](ATOMVM_TCP_HARD_LIMIT.md) を参照してください。

## 対象外

- Hex package の公開と release workflow
- 現在所有していない機材を必要とする multi-drop RS485 検証
- HW-519 以外の transceiver、USB-RS485 adapter、commercial Modbus device の追加検証
- RTU-over-TCP など標準外 transport
- test adapter を除く AtomVM 以外の runtime 向け transport adapter
