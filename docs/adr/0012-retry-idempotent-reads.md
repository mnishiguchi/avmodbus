# 0012: retry は idempotent read に限定する

## 状態

採用（entrypoint は ADR 0014 で拡張）

## 背景

managed client は disconnect 後に transport を再確立するが、失敗した request を自動 replay しない。
read polling では transient timeout / disconnect の retry が便利な一方、response が失われただけの
write を replay すると同じ操作を二度適用する危険がある。custom function と diagnostics にも
side effect の有無を library が判断できない request がある。

## 決定

- 通常の `request/4` は retry しない
- retry は明示的な `retry_request/4` として提供する
- standard read-only function と device identification だけを許可する
- write、read/write、diagnostics、encapsulated/custom function は拒否する
- retryable result は `{:error, :timeout}` と `{:error, :closed}` だけとする
- Modbus exception、invalid response、validation error はそのまま返す
- timeout は attempt ごと、retry 回数は追加 attempt 数として扱う
- attempt 間は configurable bounded exponential backoff を使う

## 理由

application が polling policy を opt-in でき、managed reconnect と組み合わせられる一方、library が
side effect のないことを保証できない request は一度も自動 replay しない。通常 request の latency と
従来 semantics も変わらない。
