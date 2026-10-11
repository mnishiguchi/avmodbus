# 0008: Client と Server handler の戻り値を統一する

## 背景

gateway が downstream Client の結果を upstream Server へ返す際、transport ごとに error 形式が異なると
変換処理が必要になる。

## 決定

- 読み取り成功は `{:ok, value}`、書き込み成功は `:ok`
- Modbus exception は `{:error, {:exception, reason}}`
- request と一致しない response は `{:error, {:invalid_response, pdu}}`
- unknown exception code は byte のまま保持する
- timeout と closed connection は `{:error, :timeout}` / `{:error, :closed}`
- exception 名と code の変換 API を提供する

## 影響

RTU / ASCII / TCP で同じ pattern matching を使え、gateway は結果をそのまま転送できる。
