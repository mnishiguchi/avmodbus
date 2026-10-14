# 0006: TCP Client が active モードのソケットを管理する

## 背景

Modbus TCP は Transaction ID で複数の要求と応答を対応付けられる。一方、AtomVM 0.7 のソケット API は
OTP で使えるオプションをすべて備えているわけではない。

## 決定

- Client プロセスが active モードのバイナリーソケットと受信バッファーを管理する
- 接続待ちは別プロセスで行い、Client 側でタイムアウトを管理する
- AtomVM と OTP の両方で使える `connect/3`、`controlling_process/2`、`send/2`、`close/1` を利用する
- 接続、キュー、応答の待ち時間を処理期限に含める
- `:max_pending` を上限として要求を送信し、Transaction ID で応答を照合する
- 不正な MBAP データ、ソケット障害、応答のないタイムアウトが続いた場合は再接続する
- 再接続は待ち時間に上限を設けた指数バックオフで行う

## 影響

ホストと AtomVM で起動・終了処理を共通化し、コーデックと接続管理を分離できる。
