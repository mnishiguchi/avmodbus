# Simultaneous-startup recovery — 2026-10-16

## 目的

両 node をほぼ同時に reset したとき、Client が `invalid_acknowledgment` を繰り返して distribution handshake が
完了しなかった startup race を host test で再現し、自動的に現在の session pair へ収束させる。

## 原因

UART または RTU receive buffer に残った以前の boot session の response が、新しい endpoint の最初の packet として
到着することがある。実装はその古い peer session を採用し、stale payload を新しい `serial_dist` reader に配達していた。
続いて現在の peer session を観測すると sequence state を reset したが、同じ packet の ACK を reset 後の state に対して
検証したため `invalid_acknowledgment` が継続した。

最初の修正で新しい session の初回 ACK validation を省略すると invalid ACK loop は消えたが、stale payload は残り、
Server が `illegal_data_value` を返した後に distribution setup が `timer_timeout` になった。

## 修正

- peer session が未確定のとき、以前の local session を acknowledge する packet は payload ごと破棄する
- 新しい peer session の最初の packet は ACK validation の対象外とする
- session boundary 後の packet には従来の future ACK と ordering validation を適用する

host test では、古い local session 宛ての data を配達しないこと、新しい session notice で旧 outgoing queue を破棄する
こと、新しい stream が sequence 1 から配送を再開することを一連の exchange として検証した。

## 実機結果

AtomVM `v0.7.0-beta.0`、9,600 baud、20 ms poll interval、96-byte operating chunk の同じ 2 台の XIAO ESP32-C5 を
使い、両 console monitor を並行起動して近接した reset を 2 回行った。

| run | first remote reply | ping/pong | transport error |
| --- | ---: | ---: | --- |
| 1 | 6,513 ms | 3 / 3 | なし |
| 2 | 6,291 ms | 3 / 3 | なし |

両 run とも genuine distribution handshake と remote process messaging が完了し、`invalid_acknowledgment`、
`illegal_data_value`、pong timeout は発生しなかった。

さらに Server を動作させたまま Client だけを reset する regression test を 1 回行った。first reply は 5,846 ms、
ping/pong は 3 / 3 成功、transport error と pong timeout は 0 であり、既存の片側 reboot recovery も維持された。

自動収束は確認できたが、first reply は AtomVM の 7 秒の distribution setup timeout に近い。baud rate、poll interval、
frame latency の安全域は roadmap の matrix 測定で引き続き調査する。
