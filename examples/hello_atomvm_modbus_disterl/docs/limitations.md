# 既知の制約

このページは現在の proof of concept の制約をまとめます。実測した条件と結果は
[作業記録](worklog/README.md) を参照してください。

- 2 node、single Unit ID、single Modbus client のみを対象とします。
- Node B は自発的に bus を駆動できず、Node A の poll latency に制約されます。
- 16-bit sequence の wraparound は host test 済みですが、65,535 message をまたぐ長時間の実機試験は未実施です。
- session ID は起動時に生成する 32-bit random value であり、永続的な node identity や collision 検出はありません。
- session 変更時の transport resynchronization と、client-only / server-only reboot 後の
  `serial_dist` 再接続は host test と実機で確認済みです。
- AtomVM `net_kernel` の distribution setup timeout は 7 秒固定です。9,600 baud の検証構成では成功しましたが、
  両 node の同時 reset 後の first reply は 2 回の実測で 6.291 秒と 6.513 秒であり、poll interval、baud、bus error に
  対する余裕は小さいです。
- wire protocol は 232-byte payload を許容しますが、今回の XIAO / HW-519 構成では上限付近の RTU frame が
  安定しませんでした。virtual UART は 96-byte operating chunk（RTU frame 114 bytes）を default とし、
  512-byte genuine distribution payload の双方向 round trip を実機確認済みです。
- 4 KiB payload の 9,600-baud 実機試験は旧 232-byte chunk 構成で `net_tick_timeout` になりました。96-byte chunk
  では未再試験です。115,200 baud では今回の HW-519 構成で distribution handshake が安定せず、baud rate の
  変更だけでは解決しませんでした。
- zero-byte の steady-state ping/pong RTT は約 0.8 秒です。512-byte payload の 30-message soak test では
  RTT の min / average / max が 5.250 / 5.425 / 7.477 秒で、direct UART より大幅に遅くなります。
- Elixir `GenServer` が生成する未実装 callback の fallback は AtomVM 0.7.0-beta.0 にない
  `erlang:phash2/2` を呼びます。このサンプルは該当する `handle_call/3` と `handle_cast/2` を明示して
  `bad_call` または `bad_cast` の stop tuple を返すため、PackBEAM warning と unsupported failure path を除去しています。
- peer reboot を検出して古い `serial_dist` reader を終了すると、AtomVM は意図した
  `{serial_read_error, closed}` の process crash report を console に表示します。
- production-ready carrier、multidrop、routing、discovery、性能最適化は対象外です。

専用 `modbus_dist` carrier は現時点では不要でした。`serial_dist` の configurable `uart_module` が
必要な integration point を提供し、既存 distribution controller を変更せず genuine distributed Erlang を
確立できました。この判断は現在の 2-node proof of concept に限ります。
