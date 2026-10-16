# 既知の制約

このページは現在の proof of concept の制約をまとめます。実測した条件と結果は
[作業記録](worklog/README.md) を参照してください。

- 2 node、single Unit ID、single Modbus client のみを対象とします。
- Node B は自発的に bus を駆動できず、Node A の poll latency に制約されます。
- virtual UART の outgoing queue は default 8 KiB / 256 chunks で、新しい write が上限を超えると
  `{:error, :queue_full}` を返し、`serial_dist` connection は fail fast します。byte limit は payload の合計であり、
  Elixir term や binary の runtime overhead を含む厳密な heap 上限ではありません。さらに `serial_dist_controller` は
  adapter 呼び出し前に frame binary を作るため、16 KiB application payload は queue check に到達する前に実機で
  OOM になりました。8 KiB application payload / 8 KiB cap は 8,304-byte write を `:queue_full` で拒否できました。
- AtomVM `serial_dist`がidle中に500 msごとにwriteするexact 2-byte sync markerは、未ACKの同じmarker 1 chunkへ
  coalesceします。Serverを約210秒先行させた後もqueue-fullにならず、Client起動後にping/pong 3 / 3を完了しました。
  これは既知のidle markerだけを対象とし、通常dataのqueue上限やbackpressureを緩和しません。
- queue-full時はlocal sessionをrolloverし、peerの旧readerも閉じます。8 KiB probeの実機runでは最初のoversize
  pingが1回timeoutした後、通常payloadのretryでhandshakeとping/pongを再確立しました。ただしqueue済み / in-flight
  stream dataは破棄され、application retryに依存します。これはdurable deliveryやexactly-onceの保証ではありません。
- 4 KiB / 44-chunk outgoing write に対し、受理済み response を3回失敗させても duplicate delivery なしで queue を
  drainし、ping/pongを完了しました。これは limited fault run であり、長時間 ACK loss の memory stability 保証ではありません。
- 16-bit sequence の wraparound は host test 済みですが、65,535 message をまたぐ長時間の実機試験は未実施です。
- session ID は起動時に生成する 32-bit random value です。local rolloverでは直前のIDとの同値を回避しますが、
  永続的な node identity や、過去またはpeerのsession IDとの一般的なcollision検出はありません。
- session 変更時の transport resynchronization と、client-only / server-only reboot 後の
  `serial_dist` 再接続は host test と実機で確認済みです。確立済み connection では、4 KiB stream の最初の
  96-byte chunk 受信後に Server を reboot しても、1 回の pong timeout 後に message を再送して復旧しました。
- 直前のtrafficがUART / RTU bufferに残り、ClientがServerより約1〜2秒先に起動した2 runでは、initial handshake中の
  peer session change後にapplication ping retryだけでは新しいhandshakeが始まりませんでした。defaultのPhase 2 Clientは
  FC-100 peer responseを確認するまで`net_kernel`を開始しません。Clientを約70秒先行させた実機runでping/pong 3 / 3、
  timeout 0を確認しました。ただしこれはinitial setupを開始する前のreadiness gateです。readiness確認後に発生する任意の
  failureを一般に回復するものではありません。AtomVM `release-0.7`向けのsetup PID保存patchでは、readiness後に
  32-byte handshake responseを40回exceptionへ置換して最初のsetupをtimeoutさせても、application retryから
  ping/pong 3 / 3へ復旧しました。旧boot libraryでは同じ条件でretryが停止しました。このpatchはlocal branchで検証済みですが、
  公式AtomVM `v0.7.0-beta.0`には未収録であり、任意のpeer half-open stateを保証しません。
- AtomVM `net_kernel` の distribution setup timeout は 7 秒固定です。9,600 baud の検証構成では成功しましたが、
  1,000 ms poll interval では setup timeout になりました。500 ms は 1 回成功したものの安全域とはみなさず、20 ms を
  default とします。
- wire protocol は 232-byte payload を許容しますが、今回の XIAO / HW-519 構成では上限付近の RTU frame が
  安定しませんでした。virtual UART は 96-byte operating chunk（RTU frame 113 bytes）を default とし、
  512-byte genuine distribution payload の双方向 round trip を実機確認済みです。
- 4 KiB payload の 9,600-baud 実機試験は旧 232-byte chunk 構成で `net_tick_timeout` になりました。現行の
  96-byte chunk / 20 ms poll では、9,600 baud で3回の往復を連続実行し、RTT min / average / max
  33.817 / 34.743 / 36.594 秒、timeout 0 で完了しました。完了後 35 秒の idle 中も connection を維持しました。
  115,200 baud では 1 往復を 22.617 秒で完了し、その後 30 秒 connection を維持しました。ただし、9,600 baud の
  連続試験と active-transfer reboot recovery は各 1 run のみで、115,200 baud の連続 traffic は未検証です。
- zero-byte の established ping/pong RTT は matrix の single run で default の 9,600 baud / 20 ms が 1.326 秒、
  115,200 baud / 20 ms が 0.890 秒でした。512-byte payload の 30-message soak test の RTT min / average / max は、
  9,600 baud で 5.250 / 5.425 / 7.477 秒、115,200 baud で 3.245 / 3.311 / 4.923 秒でした。後者も
  direct UART より大幅に遅くなります。
- Elixir `GenServer` が生成する未実装 callback の fallback は AtomVM 0.7.0-beta.0 にない
  `erlang:phash2/2` を呼びます。このサンプルは該当する `handle_call/3` と `handle_cast/2` を明示して
  `bad_call` または `bad_cast` の stop tuple を返すため、PackBEAM warning と unsupported failure path を除去しています。
- peer reboot を検出して古い `serial_dist` reader を終了すると、AtomVM は意図した
  `{serial_read_error, closed}` の process crash report を console に表示します。
- production-ready carrier、multidrop、routing、discovery、性能最適化は対象外です。

専用 `modbus_dist` carrier は現時点では不要でした。`serial_dist` の configurable `uart_module` が
必要な integration point を提供し、既存 distribution controller を変更せず genuine distributed Erlang を
確立できました。この判断は現在の 2-node proof of concept に限ります。
