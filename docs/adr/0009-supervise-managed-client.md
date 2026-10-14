# 0009: Client を Supervisor から管理できるようにする

## 背景

既存の `start_link` は通信方式を含むハンドルを返すが、Supervisor が子プロセスを起動する際は PID が必要になる。

## 決定

- 子プロセスの起動定義では Supervisor 専用の起動関数を使い、PID を返す
- Client の公開 API はハンドル、PID、登録済みのローカル名を受け付ける
- PID や名前から通信方式を判断するときは Client プロセスに問い合わせる
- `:name` はローカルの atom 名として登録する
- 管理対象の Client の停止には `stop/1` を使う
- UART を直接利用する場合は AVModbus.UART の open / close で開始・終了を管理する

## 影響

既存 API を維持したまま、通常の Supervisor ツリーから Client を起動・参照・再起動できる。
