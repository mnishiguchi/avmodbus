# 0007: Modbus TCP connection を独立 process で隔離する

## 背景

同じ connection の request order を保ちながら、複数 connection は互いに停止させず処理する必要がある。

## 決定

- listener が listen socket、admission、connection metadata を所有する
- accepted socket は connection process へ ownership transfer する
- connection process は active socket の bounded broker と wire order を保つ protocol worker を持つ
- broker は slow handler 中も受信し、worker へ未配送の binary が既定 2,048 bytes を超えた connection を閉じる
- active socket mailbox、worker が保持する data、runtime socket buffer はこの上限に含めない
- broker は isolated handler の lifecycle owner でもあり、connection 終了時に worker と handler を直接 `:kill` する
- listener は handler 実行前に ownership を登録し、broker の forced death 時も fallback owner として handler を停止する
- listener は eviction / shutdown 時に broker へ停止を要求し、全 broker で共有する 1 秒の graceful deadline 後は
  `:kill`、さらに 100 ms の shared deadline 後は待機を終了する
- socket handoff が失敗した場合は、すでに admit した broker も停止する
- AtomVM 0.7 は `active: :once` を提供せず passive receive timeout も保証しないため、active broker を使う
- protocol worker は同じ connection の request を順番に処理し、connection 間は並行動作する
- 完全な request の受信だけを activity とし、partial byte で idle deadline を延長しない
- connection 上限では、最も多く保持する address group の最古 connection を evict する
- allowlist は address と IPv4 / IPv6 prefix を扱う
- invalid MBAP stream は connection を閉じる
- authorization と handler isolation は `AVModbus.Server` に委譲する

## 影響

遅い peer と速すぎる peer の影響を connection 内に閉じ込め、connection 数と broker 内の未配送 data を制限できる。
active socket を使う runtime では、`max_buffer` だけで connection 全体の memory を厳密には制限できない。
connection の終了後に slow handler が orphan process として残らない。handler 自身が `trap_exit` を有効にしても、
connection lifecycle から独立できない。
応答不能な broker があっても listener shutdown / eviction は有限時間で進む。VM 全体または listener 自身を
強制終了した場合までは、この ownership contract の対象外とする。
