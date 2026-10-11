# 0006: managed TCP Client は AtomVM-compatible active socket を所有する

## 背景

Modbus TCP は transaction ID により request を並行処理できるが、AtomVM 0.7 の socket API は OTP の
すべての option を提供しない。

## 決定

- Client process が active binary socket と receive buffer を所有する
- blocking connect は別 process に隔離し、Client 側で timeout を管理する
- AtomVM / OTP 共通の `connect/3`、`controlling_process/2`、`send/2`、`close/1` を使う
- deadline は connection、queue、response の待ち時間を含む
- `:max_pending` まで送信し、transaction ID で response を照合する
- invalid MBAP stream、socket failure、連続 silent timeout では再接続する
- reconnect は bounded exponential backoff とする

## 影響

host と AtomVM で同じ lifecycle を使い、codec と connection management を分離できる。
