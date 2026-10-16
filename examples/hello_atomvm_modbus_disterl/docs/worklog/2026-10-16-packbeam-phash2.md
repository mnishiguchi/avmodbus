# PackBEAM `phash2/2` warning の除去 — 2026-10-16

## 目的

AtomVM 0.7.0-beta.0 向け PackBEAM で残っていた `erlang:phash2/2` warning の発生箇所と実行条件を特定し、
failure path を含めて unsupported BIF への依存をなくす。

## 調査

application の BEAM import と disassembly を確認したところ、参照は次の生成 callback だけに存在した。

- `DisterlProbe.Mailbox.handle_cast/2`
- `DisterlProbe.ModbusUART.handle_cast/2`
- `DisterlProbe.PingPong.handle_call/3`
- `DisterlProbe.PingPong.handle_cast/2`

Elixir 1.19 の `use GenServer` は、module が実装しない callback の fallback を生成する。その fallback は
`erlang:phash2(1, 1)` を Dialyzer 用の分岐に使用するため、通常の transport path では呼ばれないものの、想定外の
call または cast を受けると AtomVM では `undef` になる。AtomVM source にも `phash2` 実装は TODO として残っていた。

## 対応と結果

該当する callback を明示し、想定外の message に `bad_call` または `bad_cast` の stop tuple を返すようにした。
callback の戻り値を host test に追加し、27 test が成功した。production の application BEAM import に
`erlang:phash2/2` がないことと、PackBEAM check が warning なしで完了することも確認した。

同じ genuine distribution build の `disterl_probe.avm` は 180,320 bytes から 178,840 bytes になり、生成 fallback
を置き換えた結果 1,480 bytes 小さくなった。

この変更は通常の Modbus transport または distributed Erlang message path を変更しない。failure path は
unsupported-function crash ではなく、検査可能な GenServer stop reason になった。
