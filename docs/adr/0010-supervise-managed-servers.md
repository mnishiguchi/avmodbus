# 0010: managed Server の supervision contract を統一する

## 背景

RTU / ASCII / TCP Server の独自 handle は Supervisor の child result と一致せず、transport ごとに
戻り値を変える必要もない。

## 決定

- 各 managed Server は standard child specification を提供する
- facade と transport-specific `start_link` はどちらも `{:ok, pid}` を返す
- `:name` は local atom registration とする
- lifecycle API は raw PID または registered name を受け付ける
- server の停止 API は `stop/1` に統一する

## 影響

direct startup と supervision tree で同じ process identity を扱える。
