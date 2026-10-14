# AtomVM での memory 使用量

この資料は、実機の memory 使用量を継続的に比較する開発者向けです。AVModbus の memory 使用量は、
Seeed Studio XIAO ESP32-C5 と AtomVM
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

## 2026-10-12 基準値

共通条件は RTU、9,600 baud、UART1、GPIO23 TX、GPIO24 RX、response 待機中または idle server です。

| Role | Free heap before | Free heap after | Role delta | Process count | Managed process memory |
| --- | ---: | ---: | ---: | ---: | --- |
| RTU client | 179,656 B | 153,952 B | 25,704 B | 3 → 7 | client: 824 B |
| RTU server | 179,528 B | 144,328 B | 35,200 B | 3 → 8 | memory: 560 B; server: 1,204 B |

追加情報:

- client: largest free block 139,264 B、minimum free 151,812 B、heap 142 words、stack 10 words
- server: largest free block 126,976 B、minimum free 142,108 B
- server memory process: heap 76 words、stack 10 words
- server transport process: heap 231 words、stack 23 words
- 両 role とも計測時の binary memory は 0。client mailbox は 0、server mailbox は次の poll 1 件
- process count には UART ごとの bounded broker と専用 reader の 2 process を含む

toolchain、firmware、board、compile-time configuration、transport mode が変わる場合は別 baseline として
記録します。diagnostic probe build は通常の artifact-size budget 対象には含めません。

## 2026-10-13 TCP loopback 接続数比較

official AtomVM `v0.7.0-beta.0` image 上で、同一 board 内の TCP Server と managed Client を loopback 接続し、
network stack の warm-up 後に 1..4 connections を各 3 cycle 計測しました。各 Client は idle 接続後、
3 request を受け付け、4 件目の `:queue_full` も確認します。

| Connections | Process 数（前 / idle / active / 後） | Idle 時の free heap 減少 | Active snapshot 時の free heap 減少 |
| ---: | --- | ---: | ---: |
| 1 | `4 / 13 / 21 / 4` | 6,396–6,420 B | 11,508–13,060 B |
| 2 | `4 / 19 / 35 / 4` | 10,568–10,572 B | 22,280–23,784 B |
| 3 | `4 / 23 / 48 / 4` | 13,656–13,704 B | 32,608–34,176 B |
| 4 | `4 / 28 / 61 / 4` | 16,760–17,484 B | 40,116–44,040 B |

これは Server connection 単体の heap overhead ではなく、listener、managed Clients、accepted connections、
socket runtime state を含む deployed probe 全体の差です。active snapshot は request 投入直後の一点計測で、
測定期間中の厳密な peak ではありません。全 12 measured cycles で process 数は 4 に戻り、free heap は
probe の 32 KiB recovery bound 内に回復しました。2 connections 以上では AtomVM socket driver の
`event_queue` warning も観測したため、4 は確認済みの最大値であり、一般的な安全上限や保証値ではありません。
詳細は [TCP リソース上限レポート](ATOMVM_TCP_HARD_LIMIT.md) を参照してください。

2026-10-14 の lifecycle hardening 後にも 4 connections を 3 cycle 再実行し、process 数は
`4 / 28 / 61 / 4` に回復しました。idle 時の free heap 減少は 16,928–17,560 B、active snapshot は
41,144–43,368 B で、前日の測定と同程度でした。

## 長時間検証

startup 間の差分ではなく稼働中の推移を観測する場合は、example の
`MODBUS_HEALTH_INTERVAL_MS` を正の値にします。`modbus_health` line は uptime、connection state、
free / minimum free heap、binary memory、process count、managed process memory、mailbox length を
定期出力します。設定方法は [example README](../examples/hello_atomvm_modbus/README.md#実機-soak-test-の状態出力)
を参照してください。

health monitor は自身だけを GC し、managed Modbus process の heap には介入しません。したがって、
process memory や mailbox の継続的な増加を soak run 中に観測できます。

## 2026-10-10 実 RS485 基準値

2 台の XIAO ESP32-C5 と 2 台の HW-519 を RS485 で接続し、RTU、9,600 baud、8N1、unit ID 1、
function `0x03`、client polling interval 100 ms、health interval 10 秒で実行しました。client を 5 分、
server を 5 分 30 秒観測し、client は 1,623 request 成功、failure 0 でした。

| Role | Health snapshots | Status | Steady free heap | Largest free block | Minimum free | Process count | Managed process memory | Mailbox |
| --- | ---: | --- | ---: | ---: | ---: | ---: | --- | ---: |
| RTU client | 29 | connected | 145,632–146,080 B | 131,072 B | 143,652 B | 6–7 | client: 720 B | 0 |
| RTU server | 32 | connected | 136,684–137,424 B | 114,688–122,880 B | 133,140 B | 7 | memory: 672 B; server: 1,436 B | 0 |

client の binary memory は 0 B、server は 35 B で安定しました。この 5 分 baseline は telemetry と
real RS485 traffic の短時間安定性確認であり、roadmap の長時間 soak 完了とは扱いません。

## TCP resource probe をバージョン間で比較する

既存の `SampleApp.ResourceProbe` が出す `modbus_resource_probe cycle=...` 行をログに保存してから、
ホスト側の標準ライブラリだけで動くスクリプトで CSV に変換します。

```sh
# ESP32 の monitor 出力を /tmp/avmodbus-tcp-probe.log に保存した後
python3 scripts/summarize_tcp_resources.py \
  --label avmodbus-20261014 --atomvm-ref v0.7.0-beta.0+git.8d3e051 \
  --device 'XIAO-ESP32-C5 loopback' \
  --output /tmp/avmodbus-tcp-resource-history.csv --append \
  /tmp/avmodbus-tcp-probe.log
```

入力ログは `result=ok cycles=N` と N 個の連続した cycle を含む必要があります。
`result=error`、不完全な実行、重複 cycle、壊れた CSV header は失敗扱いとし、不確かな baseline を保存しません。

CSV には firmware label、AtomVM reference、device、cycle、connection 数、baseline / idle /
active / cleanup の process count・free heap・largest free block と、free heap の減少量を記録します。
複数実行を `--append` でまとめ、変更前後を同じ条件で比較してください。

**重要:** これらの値は probe 実行中の snapshot であり、瞬間的な peak の保証ではありません。
また、loopback 測定値には server だけでなく client と AtomVM runtime の負荷が含まれます。
検証範囲を超える接続数で probe を実行しないでください。
