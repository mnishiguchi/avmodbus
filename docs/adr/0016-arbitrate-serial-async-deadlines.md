# 0016: serial async result は deadline arbiter で一度だけ通知する

## 背景

serial Client は transaction 中に次の mailbox message を処理しないため、queue 内の async request は
deadline を過ぎても timeout 通知が遅れる可能性がある。

## 決定

- 正の timeout を持つ async request ごとに軽量な deadline arbiter を起動する
- arbiter は transaction result と timeout の先着一方だけを recipient へ送る
- deadline 後の late result は破棄する
- zero-timeout の即時確認 path は維持する
- UART ownership、serialization、reconnect は Client process に残す
- TCP は既存の per-request timer を使う

## 影響

UART ownership を変えず、deadline 内に exactly-once result を通知できる。
