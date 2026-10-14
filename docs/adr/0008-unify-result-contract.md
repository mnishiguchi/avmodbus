# 0008: Client と Server ハンドラーの戻り値を統一する

## 背景

ゲートウェイで下流の Client の結果を上流の Server へ返すとき、通信方式ごとにエラー形式が違うと
余分な変換処理が必要になる。

## 決定

- 読み取り成功は `{:ok, value}`、書き込み成功は `:ok`
- Modbus の例外応答は `{:error, {:exception, reason}}`
- 要求と一致しない応答は `{:error, {:invalid_response, pdu}}`
- 未知の例外コードはバイト値のまま保持する
- タイムアウトと切断は `{:error, :timeout}` / `{:error, :closed}`
- 例外名とコードの相互変換 API を提供する

## 影響

RTU / ASCII / TCP で同じパターンマッチが使えるため、ゲートウェイでの結果の受け渡しが簡単になる。
