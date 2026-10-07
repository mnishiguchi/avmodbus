# 0014: client request option を keyword API に統一する

## 状態

採用

## 背景

AVModbus の request helper は timeout を positional argument、asynchronous request は recipient も
別 argument で受け取っていた。これは小さい API だが、option を追加するたび arity が増え、
一般的な per-request keyword API から移行する application に不要な書き換えが生じる。

ADR 0012 では retry を明示的な `retry_request/4` に限定した。その安全 policy は維持しつつ、
通常の read helper からも明示的に選べる方が polling code を簡潔にできる。

## 決定

- synchronous request の最後の引数は従来の timeout integer と keyword options の両方を受け付ける
- keyword options は `timeout:`、`retries:`、`backoff:` とする
- `retries:` の既定値は 0 とし、指定しない request の latency と送信回数を変えない
- 正の `retries:` は ADR 0012 の idempotent-read validation と transient-error policy を通す
- `retry_request/4` は explicit generic API として維持する
- asynchronous request は `timeout:` と `to:` を受け付け、positional form も維持する
- unknown / invalid option は request を送信する前に tagged error で返す

## 理由

keyword による呼び出し形を選べるため移行が容易になり、今後 option が増えても arity を増やさずに
済む。従来 API は壊さず、retry は引き続き caller の opt-in であり、ambiguous write を replay しない。
