# ロードマップ

AVModbus は、AtomVM で Modbus RTU / ASCII / TCP の Client と Server を提供します。
主要機能と当初予定した検証は完了しており、現在は機能追加より互換性と安定性の維持を優先します。
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

## 継続して確認すること

- AtomVM `release-0.7` または firmware を更新したときの API / runtime compatibility
- protocol や queue policy を変更したときの property / stress / soak test
- device profile を変更したときの UART timing、memory、artifact size
- socket、UART、peer failure 後に process と resource が回復すること

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
- USB-RS485 adapter / commercial Modbus device の追加検証
- RTU-over-TCP など標準外 transport
- test adapter を除く AtomVM 以外の runtime 向け transport adapter
