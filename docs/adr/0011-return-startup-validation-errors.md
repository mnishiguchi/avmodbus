# 0011: startup validation は tagged error を返す

## 状態

採用

## 背景

client、memory、transport 別 server はそれぞれ startup option を検証していたが、invalid handler を
TCP server だけが拒否する、invalid name の reason が module 間で異なる、non-list options が
一部 entrypoint で function-clause error になる、という差があった。supervisor から起動する場合も
direct startup と同じ原因を判定できる必要がある。

## 決定

- public startup API は configuration error で raise せず `{:error, reason}` を返す
- non-list options は `:invalid_options` とする
- unknown option は `{:invalid_option, option}` とし offending value を保持する
- option value の error は `:invalid_<name>_option` に統一する
- invalid handler は全 server transport で `:invalid_handler` とする
- handler、name、option は UART、socket、process を確保する前に検証する
- supervision 専用 entrypoint は direct startup と同じ validation error を返す

## 理由

embedded application は configuration error を boot failure policy に組み込みやすくなり、test と
supervisor report も例外文字列ではなく安定した reason を比較できる。resource acquisition 前に
拒否することで、invalid configuration による一時的な UART / port ownership も避けられる。
