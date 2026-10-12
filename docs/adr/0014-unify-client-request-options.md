# 0014: Client request option を keyword API に統一する

## 背景

timeout や async recipient を positional argument で増やすと、API arity と call site の意味が
分かりにくくなる。

## 決定

- request の最後の引数は keyword options だけを受け付ける
- sync option は `timeout:`、`retries:`、`backoff:`
- device identification helper の category は `category:` とし、既定値は `:basic`
- retry の既定値は 0 とし、正の値は ADR 0012 の安全性検証を通す
- async option は `timeout:` と `to:`
- timeout integer と async recipient の positional form は提供しない
- retry policy を明示する `retry_request/4` は維持する
- invalid option は送信前に tagged error で返す

## 影響

request option の追加で arity を増やさず、call site だけで timeout、category、recipient の意味を判別できる。
