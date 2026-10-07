# 設計判断記録

長期的に残す価値のある設計判断だけを記録します。現在の構造や使い方は [`../ARCHITECTURE.md`](../ARCHITECTURE.md) と root `README.md` を正とします。

- [0001: Modbus library と example application を分離する](0001-project-scope.md)
- [0002: protocol core と transport を分離する](0002-protocol-transport-boundary.md)
- [0003: serial client / server は managed process で policy を共有する](0003-managed-serial-policy.md)
- [0004: server application boundary を transport から分離する](0004-server-boundary.md)
- [0005: AtomVM prerelease と host toolchain を pin する](0005-atomvm-toolchain.md)
- [0006: managed TCP client は AtomVM-compatible active socket を所有する](0006-use-atomvm-compatible-active-tcp-client.md)
- [0007: Modbus TCP connection を独立 process で隔離する](0007-isolate-modbus-tcp-connections.md)
- [0008: client と server handler の result contract を統一する](0008-unify-result-contract.md)
- [0009: managed client を OTP supervision と両立させる](0009-supervise-managed-client.md)
- [0010: managed server の supervision contract を統一する](0010-supervise-managed-servers.md)
- [0011: startup validation は tagged error を返す](0011-return-startup-validation-errors.md)
- [0012: retry は idempotent read に限定する](0012-retry-idempotent-reads.md)
- [0013: Server module を transport startup facade にする](0013-unify-server-startup.md)
- [0014: client request option を keyword API に統一する](0014-unify-client-request-options.md)
- [0015: Modbus/TCP Security は必要な AtomVM TLS capability まで fail closed する](0015-fail-closed-without-mutual-tls.md)
- [0016: serial asynchronous result は deadline arbiter で一度だけ通知する](0016-arbitrate-serial-async-deadlines.md)
- [0017: TCP client の待機 queue を制限する](0017-bound-tcp-client-queue.md)
- [0018: managed client の既定 request timeout を startup option にする](0018-configure-client-default-timeout.md)
- [0019: UART hardware configuration を transport boundary に置く](0019-keep-uart-configuration-at-transport-boundary.md)
