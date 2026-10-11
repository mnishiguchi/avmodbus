# 0012: retry は idempotent read に限定する

## 背景

read の一時的な timeout は再試行できるが、response を失った write を再送すると操作が重複する可能性がある。

## 決定

- retry は caller が明示した場合だけ行う
- standard read-only function と device identification だけを許可する
- write、read/write、diagnostics、custom function は拒否する
- `:timeout` と `:closed` だけを retry 対象にする
- Modbus exception、invalid response、validation error は再試行しない
- attempt 間は bounded exponential backoff とする
- `retry_request/4` を generic entrypoint として維持する

## 影響

polling の一時障害には対応しつつ、side effect のある request を自動 replay しない。
