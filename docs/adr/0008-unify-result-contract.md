# 0008: client と server handler の result contract を統一する

## 状態

採用

## 背景

Modbus gateway は upstream server handler から downstream client を呼び出す。
client が wire exception を `{:modbus_exception, reason}`、handler が
`{:exception, reason}` と表現すると、gateway ごとに変換が必要になる。
malformed response も function、length、write echo ごとの内部理由を公開すると、
transport 間で error handling が分岐する。

## 決定

- client と server handler は同じ result contract を使う
- Modbus exception は `{:error, {:exception, reason}}` とする
- request の function、length、count、write echo に一致しない response は
  `{:error, {:invalid_response, pdu}}` とする
- known exception code は atom、unknown code は byte のまま保持する
- `AVModbus.exception_name/1` と `AVModbus.exception_code/1` を公開する
- timeout と unavailable connection はそれぞれ `{:error, :timeout}` と
  `{:error, :closed}` のまま transport failure として区別する

## 理由

gateway handler が downstream client result を変換せず返せる。application は RTU、ASCII、
TCP で同じ pattern matching を使え、decoder の内部構造を public API として固定せずに済む。
