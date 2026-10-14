# 0010: Server を Supervisor から同じ方法で管理する

## 背景

RTU / ASCII / TCP の Server が独自のハンドルを返すと、Supervisor の子プロセス起動時の戻り値と一致しない。
通信方式によって戻り値を変える必要もない。

## 決定

- 各 Server は標準の子プロセス起動定義を提供する
- 共通 API と通信方式別の `start_link` は、どちらも `{:ok, pid}` を返す
- `:name` はローカルの atom 名として登録する
- 起動・終了の API は PID または登録済みの名前を受け付ける
- Server の停止には `stop/1` を使う

## 影響

直接起動した場合も Supervisor から起動した場合も、Server を PID で扱える。
