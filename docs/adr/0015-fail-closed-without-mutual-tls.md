# 0015: Modbus/TCP Security は相互認証 TLS に対応するまで拒否する

## 背景

Modbus/TCP Security には TLS 1.2 以降に加え、双方の証明書、通信相手の検証、Client の識別情報に基づく
アクセス許可が必要になる。対象の AtomVM 0.7 の SSL API では、これらをすべて満たせない。

## 決定

- Client / Server の `tls:`、`ssl:`、`transport: :tls` は `{:error, :tls_not_supported}` を返す
- 相手を検証しない `verify_none` や Client 側だけの TLS を、Modbus/TCP Security として提供しない
- 対応していない TLS 指定を、暗号化なしの通信へ切り替えない

## 再評価条件

AtomVM が次を提供したときに再検討する。

- TLS 1.2 以降での Client / Server 通信と、上限付きのハンドシェイクタイムアウト
- 証明書、秘密鍵、信頼する認証局の設定
- 通信相手の証明書検証と、Client 証明書の必須化
- アクセス許可の判定に渡せる、検証済みの通信相手の識別情報

## 影響

暗号化だけで相互認証ができたと誤解されることを防ぎ、未対応の場合は明示的にエラーを返す。
