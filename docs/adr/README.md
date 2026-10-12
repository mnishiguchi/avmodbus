# 設計判断記録

現在採用している長期的な設計判断を記録します。実装の詳細は
[Architecture](../ARCHITECTURE.md)、利用方法は root `README.md` と [開発者ガイド](../DEVELOPMENT.md) を
正とします。判断を変更する場合は既存 ADR を書き換えず、新しい ADR で置き換えます。

## 境界と対象

- [0001: library と example を分離する](0001-project-scope.md)
- [0002: protocol core と transport を分離する](0002-protocol-transport-boundary.md)
- [0004: Server application と transport を分離する](0004-server-boundary.md)
- [0005: runtime target と host toolchain を分離する](0005-atomvm-toolchain.md)
- [0019: UART hardware 設定を transport boundary に置く](0019-keep-uart-configuration-at-transport-boundary.md)

## Client / Server lifecycle

- [0003: serial policy を managed process で共有する](0003-managed-serial-policy.md)
- [0006: TCP Client が active socket を所有する](0006-use-atomvm-compatible-active-tcp-client.md)
- [0007: TCP connection を process で隔離する](0007-isolate-modbus-tcp-connections.md)
- [0009: Client を supervision と両立させる](0009-supervise-managed-client.md)
- [0010: Server の supervision contract を統一する](0010-supervise-managed-servers.md)
- [0013: `AVModbus.Server` を startup facade にする](0013-unify-server-startup.md)

## API と障害処理

- [0008: Client と handler の戻り値を統一する](0008-unify-result-contract.md)
- [0011: 起動時の設定エラーを tagged error で返す](0011-return-startup-validation-errors.md)
- [0012: retry を idempotent read に限定する](0012-retry-idempotent-reads.md)
- [0014: request option を keyword API に統一する](0014-unify-client-request-options.md)
- [0016: serial async result を deadline 内に一度だけ通知する](0016-arbitrate-serial-async-deadlines.md)
- [0017: TCP Client の待機 queue を制限する](0017-bound-tcp-client-queue.md)
- [0018: Client の既定 timeout を起動時に設定する](0018-configure-client-default-timeout.md)
- [0020: async request の受付を同期して resource 上限を守る](0020-admit-async-requests-synchronously.md)

## Security

- [0015: 相互認証 TLS が利用できるまで fail closed する](0015-fail-closed-without-mutual-tls.md)
