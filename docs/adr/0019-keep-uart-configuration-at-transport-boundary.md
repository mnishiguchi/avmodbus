# 0019: UART hardware configuration を transport boundary に置く

## 背景

peripheral、pin、baud、parity などを Client / Server option に重複させると、protocol policy と board wiring が
混在し、reopen state も複数箇所に分散する。

## 決定

- built-in `AVModbus.UART` の hardware 設定は application configuration に置く
- managed Client / Server に同じ UART option を追加しない
- serial transport は instance 設定を受け取る `open/1` を必須 callback とする
- runtime 選択が必要な application は UART handle または custom transport を注入する
- injected handle の close / reopen は application が所有する
- managed reopen を保つ runtime override が必要になった場合は transport configuration として設計する

## 影響

固定 board profile は小さく一貫した設定で再接続できる。動的な複数 UART の用途では application が
ownership と recovery を明示する。
