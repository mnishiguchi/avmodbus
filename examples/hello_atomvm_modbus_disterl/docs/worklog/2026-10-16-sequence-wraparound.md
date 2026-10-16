# Sequence wraparound — 2026-10-16

## 目的

長時間接続で 16-bit sequence が 65,535 に達した後も、session を再生成せずに配送を継続できるようにする。

## 実装

- data sequence の範囲を `1..65,535` とし、65,535 の次を 1 とした
- receiver の期待値と ACK の新旧判定を wraparound 対応にした
- ACK 0 は従来どおり「ACK なし」として予約した
- 65,535 message が未 ACK のまま残る場合は sequence を再利用せず、追加の queue を拒否する

ACK は 65,535 個の ring 上で基準 sequence から後方の距離を求め、半周以内を current または stale と
判定する。stop-and-wait の通常動作では current ACK または直前の重複 ACK だけが現れるが、数値の大小を
直接比較しないことで `65,535 -> 1` の境界でも同じ規則を適用できる。

## Host test

次の case を追加した。

- sequence 65,535 と wrap 後の sequence 1 を順番に一度だけ配達する
- wrap 境界をまたいだ古い ACK 65,535 を無視し、未来の ACK 2 を拒否する
- sequence 空間全体が未 ACK の場合に新しい queue を拒否する

実機で 65,535 message を送る長時間試験はまだ行っていない。
