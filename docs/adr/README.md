# 設計判断記録

現在採用している長期的な設計判断を記録します。実装の詳細は
[アーキテクチャ](../architecture.md)、利用方法は [README](../../README.md) と [開発者ガイド](../development.md) を
正とします。判断を変更する場合は既存 ADR を書き換えず、新しい ADR で置き換えます。

## 追加と更新

- ファイル名は `NNNN-lowercase-kebab-case.md` とし、番号は連番にします。
- ADR には、判断が必要になった背景、採用する方針、その影響を簡潔に記録します。
- 実装手順や一時的な検証結果は ADR に含めず、アーキテクチャまたは `docs/development/` に置きます。
- 採用済みの判断を変更するときは既存 ADR を書き換えず、新しい ADR を追加して置き換え関係を記録します。
- ADR を追加したら、この一覧の適切な分類にもリンクを追加します。

## 境界と対象

- [0001: ライブラリとサンプルアプリを分ける](0001-project-scope.md)
- [0002: プロトコル処理と通信方式を分離する](0002-protocol-transport-boundary.md)
- [0004: Server の処理と通信方式を分離する](0004-server-boundary.md)
- [0005: AtomVM と開発用ツールのバージョンを分けて管理する](0005-atomvm-toolchain.md)
- [0019: UART の設定をトランスポート層で管理する](0019-keep-uart-configuration-at-transport-boundary.md)

## Client / Server の起動と終了

- [0003: シリアル通信の管理方針を共有する](0003-managed-serial-policy.md)
- [0006: TCP Client が active モードのソケットを管理する](0006-use-atomvm-compatible-active-tcp-client.md)
- [0007: TCP の接続ごとに処理を分ける](0007-isolate-modbus-tcp-connections.md)
- [0009: Client を Supervisor から管理する](0009-supervise-managed-client.md)
- [0010: Server を Supervisor から管理する](0010-supervise-managed-servers.md)
- [0013: Client / Server の通信方式の指定を統一する](0013-unify-server-startup.md)

## API と障害処理

- [0008: Client と Server ハンドラーの戻り値を統一する](0008-unify-result-contract.md)
- [0011: 起動時の設定エラーを戻り値で知らせる](0011-return-startup-validation-errors.md)
- [0012: 自動リトライを安全な読み取りに限定する](0012-retry-idempotent-reads.md)
- [0014: 要求オプションをキーワード形式に統一する](0014-unify-client-request-options.md)
- [0016: シリアル通信の非同期結果を期限に従って一度だけ通知する](0016-arbitrate-serial-async-deadlines.md)
- [0017: TCP Client の待機キューを制限する](0017-bound-tcp-client-queue.md)
- [0018: Client の既定タイムアウトを設定する](0018-configure-client-default-timeout.md)
- [0020: 非同期要求の受付時にリソース上限を確認する](0020-admit-async-requests-synchronously.md)

## セキュリティ

- [0015: Modbus/TCP Security は相互認証 TLS に対応するまで拒否する](0015-fail-closed-without-mutual-tls.md)
