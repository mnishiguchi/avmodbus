# 0004: session ID で片側再起動後の transport を再同期する

## 背景

version 1 の header は sequence と acknowledgment だけを持っていた。片側だけを再起動すると、再起動した側は
sequence state を失うため、相手が送る既存の in-flight sequence を out-of-order と判定する。また、再起動前の
session に対する ACK を新しい送信 state へ適用する可能性があった。

## 決定

- transport header を version 2 とし、sender の 32-bit `session` を追加する
- ACK の対象を表す 32-bit `acknowledged_session` を追加する
- ESP32 では起動時に `atomvm:random/0` で non-zero session ID を生成する
- local session と一致しない ACK は stale とみなして無視する
- 新しい peer session の最初の data sequence を receive baseline として受け入れる
- 既知の peer が session を変更した場合、その peer 向けの古い outgoing queue を破棄する
- virtual UART の infinite read を `{:error, :closed}` で終了し、`serial_dist` を idle state へ戻す
- header の増加分だけ payload 上限を 240 bytes から 232 bytes に減らし、custom payload 全体を 245 bytes に保つ

## 影響

transport は相手が state を失ったことを検出し、surviving peer の in-flight sequence を 1 からでなくても受け入れられる。
古い distribution stream の data を新しい peer process へ渡さず、既存 `serial_dist` link manager で handshake をやり直せる。
session ID は確率的な識別子であり、永続 identity や cryptographic authentication ではない。既存の version 1 packet
とは wire-compatible でないため、両 endpoint を version 2 に更新する必要がある。

この判断は [0002](0002-use-fc100-stop-and-wait-transport.md) の payload 上限と、session ID を持たないことによる
再同期の制約を置き換える。
