# 0015: Modbus/TCP Security は相互認証 TLS が利用できるまで fail closed する

## 背景

Modbus/TCP Security には TLS 1.2 以降、双方の certificate、peer verification、Client identity に基づく
authorization が必要である。対象 AtomVM 0.7 の SSL API はこれを満たさない。

## 決定

- Client / Server の `tls:`、`ssl:`、`transport: :tls` は `{:error, :tls_not_supported}` を返す
- `verify_none` の Client-only TLS を Modbus/TCP Security として提供しない
- unsupported TLS を暗号化なしへ切り替えない

## 再評価条件

AtomVM が次を提供したときに再検討する。

- TLS 1.2 以降の Client / Server transport と bounded handshake timeout
- certificate、private key、CA trust の設定
- peer certificate verification と必須の Client certificate
- authorization に渡せる検証済み peer identity

## 影響

暗号化だけを安全な相互認証と誤認させず、明示的に失敗する。
