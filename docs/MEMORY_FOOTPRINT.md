# AtomVM memory footprint

AVModbus の device memory footprint は、Seeed Studio XIAO ESP32-C5 と AtomVM
`v0.7.0-beta.0` 上で、role startup 直前と startup 後の ESP32 heap、および managed process の
`process_info/2` を記録します。

## 計測方法

memory probe を有効にした production example を role ごとに clean build し、flash 後の
`modbus_memory` line を取得します。

```sh
cd examples/hello_atomvm_modbus
MIX_ENV=prod mix clean

MODBUS_MEASURE_MEMORY=true MIX_ENV=prod mix atomvm.packbeam
MODBUS_MEASURE_MEMORY=true MIX_ENV=prod mix atomvm.esp32.flash --port /dev/ttyACM0
mix atomvm.esp32.monitor --port /dev/ttyACM0 --timeout 12

MIX_ENV=prod mix clean
MODBUS_ROLE=server MODBUS_MEASURE_MEMORY=true MIX_ENV=prod mix atomvm.packbeam
MODBUS_ROLE=server MODBUS_MEASURE_MEMORY=true MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM0
mix atomvm.esp32.monitor --port /dev/ttyACM0 --timeout 8
```

probe は role startup 前後で GC を実行し、startup 後 100 ms 待ってから次を出力します。

- ESP32 free heap、largest free block、minimum-ever free heap
- reference-counted binary memory
- process count
- managed client / server / memory process の推定 bytes、heap words、stack words、mailbox length

free heap delta は managed process heap だけでなく、role module の load、UART resource、driver state も
含む deployed-role の増分です。`process_info/2` の `:memory` は個別 BEAM process の推定値です。

## 2026-10-09 baseline

共通条件は RTU、9,600 baud、UART1、GPIO11 TX、GPIO12 RX、response 待機中または idle server です。

| Role | Free heap before | Free heap after | Role delta | Process count | Managed process memory |
| --- | ---: | ---: | ---: | ---: | --- |
| RTU client | 179,720 B | 159,528 B | 20,192 B | 3 → 5 | client: 628 B |
| RTU server | 179,576 B | 149,992 B | 29,584 B | 3 → 6 | memory: 560 B; server: 1,024 B |

追加情報:

- client: largest free block 139,264 B、minimum free 157,380 B、heap 93 words、stack 10 words
- server: largest free block 131,072 B、minimum free 147,764 B
- server memory process: heap 76 words、stack 10 words
- server transport process: heap 187 words、stack 24 words
- 両 role とも計測時の binary memory と managed mailbox length は 0

toolchain、firmware、board、compile-time configuration、transport mode が変わる場合は別 baseline として
記録します。diagnostic probe build は通常の artifact-size budget 対象には含めません。

## 長時間検証

startup 間の差分ではなく稼働中の推移を観測する場合は、example の
`MODBUS_HEALTH_INTERVAL_MS` を正の値にします。`modbus_health` line は uptime、connection state、
free / minimum free heap、binary memory、process count、managed process memory、mailbox length を
定期出力します。設定方法は [example README](../examples/hello_atomvm_modbus/README.md#device-soak-telemetry)
を参照してください。

health monitor は自身だけを GC し、managed Modbus process の heap には介入しません。したがって、
process memory や mailbox の継続的な増加を soak run 中に観測できます。
