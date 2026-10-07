# 0019: UART hardware configuration を transport boundary に置く

## 状態

採用

## 背景

AtomVM の `:uart.open/2` は peripheral、pin、baud、data bits、parity、stop bits を runtime option として
受け取れる。一方、現在の built-in `AVModbus.UART` adapter はこれらを firmware build 時の application
configuration から取得し、transport failure 後も同じ設定で reopen する。

client / server option に同じ UART 設定を追加すると、protocol policy と board wiring が混在し、serial
client、RTU server、ASCII facade のそれぞれで validation、ownership、reopen state を重複して持つ。

## 決定

- built-in `AVModbus.UART` の hardware 設定は application configuration に置く
- managed client / server に peripheral、pin、line-coding option を追加しない
- runtime UART ownership が必要な application は、AtomVM `:uart` または custom transport で handle を
  open し、既存の injected transport API に渡す
- injected handle の close / reopen は application の責務とする
- 実 device で managed reopen を保つ runtime override の必要性が確認された場合は、client / server
  option の複製ではなく transport configuration として再設計する

## 理由

embedded deployment では pin assignment と基本 line coding は board profile に属する。compile-time
configuration は不要な runtime validation と state を artifact に持ち込まず、disconnect 後も同じ設定で
確実に reopen できる。動的な用途は既存の transport injection で protocol core を変更せず扱える。

## 影響

baud ごとの実機検証は firmware configuration を切り替えて build する。複数 UART や runtime-selected
line coding を使う application は ownership と recovery を明示的に実装する必要がある。この制約が
実運用で不十分と判明した場合は roadmap の再評価項目から新しい transport contract を設計する。
