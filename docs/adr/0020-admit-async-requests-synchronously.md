# 0020: async request の受付を同期して resource 上限を守る

## 背景

`send_request/4` が `GenServer.cast` で request を投入すると、Client が `:max_queue` を確認する前に
mailbox へ message を積める。serial Client では deadline arbiter も受付結果より先に生成されるため、
内部 queue だけを制限しても library が作る process 数の上限にならない。

## 決定

- Serial / TCP とも、async request は短い synchronous admission で capacity を確認する
- 受付後の wire transaction と result notification は非同期のままにする
- 受付成功時だけ reference を返し、完了 result を同じ reference で一度通知する
- `:queue_full` や `:closed` は reference を作らず、受付結果として直接返す
- serial deadline arbiter は受付済みの active / queued request にだけ生成する
- queue の上限と deadline の扱いは ADR 0016 / 0017 を維持する

## 影響

単一 producer は一方的な cast で Client mailbox や helper process を増やせない。
caller は `send_request/4` の戻り値を reference と error に分け、明示的に backpressure を処理する。
