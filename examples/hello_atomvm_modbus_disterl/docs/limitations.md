# 既知の制約

このページは現在の proof of concept の制約をまとめます。実測した条件と結果は
[作業記録](worklog/README.md) を参照してください。

- 2 node、single Unit ID、single Modbus client のみを対象とします。
- Node B は自発的に bus を駆動できず、Node A の poll latency に制約されます。
- virtual UART の outgoing queue は default 16 KiB / 256 chunks で、新しい write が上限を超えると
  `{:error, :queue_full}` を返し、`serial_dist` connection は fail fast します。byte limit は payload の合計であり、
  Elixir term や binary の runtime overhead を含む厳密な heap 上限ではありません。
- 16-bit sequence の wraparound は host test 済みですが、65,535 message をまたぐ長時間の実機試験は未実施です。
- session ID は起動時に生成する 32-bit random value であり、永続的な node identity や collision 検出はありません。
- session 変更時の transport resynchronization と、client-only / server-only reboot 後の
  `serial_dist` 再接続は host test と実機で確認済みです。確立済み connection では、4 KiB stream の最初の
  96-byte chunk 受信後に Server を reboot しても、1 回の pong timeout 後に message を再送して復旧しました。
- 直前の traffic が UART / RTU buffer に残り、Client が Server より約 1〜2 秒先に起動した 2 run では、initial
  handshake 中の peer session change 後に application ping retry だけでは新しい handshake が始まりませんでした。
  Server-first startup では回避できましたが、session change 後の connection retry trigger は未解決です。
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
