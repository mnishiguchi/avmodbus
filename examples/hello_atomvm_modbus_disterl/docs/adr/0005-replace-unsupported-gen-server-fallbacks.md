# 0005: GenServer の unsupported fallback callback を置き換える

## 背景

Elixir 1.19 の `use GenServer` は、module が実装しない `handle_call/3` と `handle_cast/2` の fallback を生成する。
この fallback は Dialyzer の解析を避ける分岐に `erlang:phash2/2` を使うが、AtomVM 0.7.0-beta.0 はこの BIF を
実装していない。そのため PackBEAM は application BEAM に unsupported function があると警告し、想定外の call
または cast を受けた場合は意図した GenServer error ではなく `undef` で失敗する。

## 決定

このサンプルで不足している `handle_call/3` と `handle_cast/2` を明示的に実装し、それぞれ
`{:stop, {:bad_call, message}, state}` と `{:stop, {:bad_cast, message}, state}` を返す。通常の application path に
新しい protocol behavior は加えず、想定外の同期・非同期 request だけを明示的に process termination とする。

## 影響

application BEAM は `erlang:phash2/2` を参照せず、AtomVM 0.7.0-beta.0 向け PackBEAM check は warning なしで
完了する。将来 AtomVM が `phash2/2` を実装しても、この明示的な failure behavior は維持される。Elixir の生成する
fallback と異なり詳細な process 名を含む exception text は作らないが、この実験では unsupported BIF に依存しない
決定的な停止理由を優先する。
