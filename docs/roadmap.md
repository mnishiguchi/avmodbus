# ロードマップ

AVModbus は RTU・ASCII・TCP の Client / Server と、基本的なエラー処理・再接続処理を実装しています。
現在は、新機能を増やすよりも **動作確認と API の安定化** を優先しています。

実装済みの機能は [README](../README.md)、経緯は [開発記録](development/worklog.md) と
[設計判断](adr/README.md) を参照してください。

Modbus RTU 上で AtomVM の distributed Erlang を動かす調査は、AVModbus core の機能計画とは
分けて [standalone example のロードマップ](../examples/hello_atomvm_modbus_disterl/docs/roadmap.md)
で管理しています。実機での remote messaging は確認済みですが、production-ready な carrier
として AVModbus がサポートしているわけではありません。

## 次に確認すること

- [ ] GitHub Actions の相互運用テストが継続して成功することを確認する
- [ ] リリース候補を別のアプリケーションから利用し、パッケージ内容を確認する
- [ ] 公開 API と利用例が一致していることを確認する
- [ ] 利用できる機材が増えたら、別の RS485 モジュールや商用機器でも検証する

具体的な手順は [リリース前チェックリスト](development/release-checklist.md) にまとめています。

## 現在わかっている制約

- **Modbus/TCP Security:** 対象の AtomVM では相互認証 TLS に必要な機能が不足しています。
  TLS オプションを指定しても平文通信へ切り替えず、エラーを返します。
- **ESP32-C5 の TCP リソース:** 接続負荷が高すぎる場合、AtomVM が正常なエラーを返す前に
  応答しなくなることがあります。検証済みの範囲内で使ってください。
- **実機検証:** 現時点では主に XIAO ESP32-C5 と HW-519 を使っています。

[互換性表](compatibility.md)には確認済みの組み合わせを、
[TCP の制約](limitations.md)には調査結果を記録しています。

## 今回は対象としないこと

- RTU-over-TCP などの独自方式
- 十分な検証環境がない機材への対応保証
- 実測に基づかない最適化や大規模な内部構造の変更

公開方法と時期は未定です。Hex への公開は、機能実装とは別に判断します。
