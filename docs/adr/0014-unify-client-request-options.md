# 0014: Client request option を keyword API に統一する

## 背景

timeout や async recipient を positional argument だけで増やすと、API arity と移行負担が増える。

## 決定

- request の最後の引数は従来の timeout integer と keyword options の両方を受け付ける
- sync option は `timeout:`、`retries:`、`backoff:`
- retry の既定値は 0 とし、正の値は ADR 0012 の安全性検証を通す
- async option は `timeout:` と `to:`
- positional form と `retry_request/4` は維持する
- invalid option は送信前に tagged error で返す

## 影響

後方互換を保ちながら request 単位の option を拡張できる。
