# 既知の制約

このページは現在の proof of concept の制約をまとめます。実測した条件と結果は
[作業記録](worklog/README.md) を参照してください。

- 2 node、single Unit ID、single Modbus client のみを対象とします。
- Node B は自発的に bus を駆動できず、Node A の poll latency に制約されます。
- 16-bit sequence の wraparound は未実装です。
- session ID は起動時に生成する 32-bit random value であり、永続的な node identity や collision 検出はありません。
- session 変更時の transport resynchronization と、client-only / server-only reboot 後の
  `serial_dist` 再接続は host test と実機で確認済みです。
- AtomVM `net_kernel` の distribution setup timeout は 7 秒固定です。9,600 baud の検証構成では成功しましたが、
  poll interval、baud、bus error に対する余裕は小さいです。
- `serial_dist` の最大 frame は Modbus chunk より大きいため adapter が 232-byte chunk に分割しますが、
  大きな distribution payload の stress test は未実施です。
- 実測した steady-state ping/pong RTT は約 0.8 秒で、direct UART より大幅に遅くなります。
- PackBEAM checker は Elixir `GenServer` が生成する error-reporting path に含まれる
  `erlang:phash2/2` を警告します。検証した normal path は両方の実機で動作しました。
- peer reboot を検出して古い `serial_dist` reader を終了すると、AtomVM は意図した
  `{serial_read_error, closed}` の process crash report を console に表示します。
- production-ready carrier、multidrop、routing、discovery、性能最適化は対象外です。

専用 `modbus_dist` carrier は現時点では不要でした。`serial_dist` の configurable `uart_module` が
必要な integration point を提供し、既存 distribution controller を変更せず genuine distributed Erlang を
確立できました。この判断は現在の 2-node proof of concept に限ります。
