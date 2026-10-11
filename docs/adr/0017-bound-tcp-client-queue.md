# 0017: TCP Client の待機 queue を制限する

## 背景

`:max_pending` を超えた未送信 request が無制限に溜まると、AtomVM device の memory と timer を使い続ける。

## 決定

- 未送信 request を `:max_queue` で制限する
- 既定値は 64、`0..65_536` または明示的な `:infinity` を許可する
- pending slot があれば `max_queue: 0` でも直接送信できる
- queue が満杯なら `{:error, :queue_full}` を即時返す
- 既存 request は追い出さず、capacity 回復後は新しい request を受け付ける
- `:queue_full` は retry しない

## 影響

memory 使用量に上限を設け、caller が明示的に backpressure を処理できる。
