# 0009: managed Client を OTP supervision と両立させる

## 背景

既存の `start_link` は transport を含む tagged handle を返すが、Supervisor の child start は raw PID を必要とする。

## 決定

- child specification は supervision 専用 start function を使い、raw PID を返す
- public Client API は tagged handle、raw PID、registered local name を受け付ける
- raw PID / name の transport kind は Client process に問い合わせる
- `:name` は local atom registration とする
- managed lifecycle API は `stop/1` に統一する
- raw UART の lifecycle は AVModbus.UART の open / close で管理する

## 影響

既存 API を保ったまま通常の supervision tree から Client を起動・参照・再起動できる。
