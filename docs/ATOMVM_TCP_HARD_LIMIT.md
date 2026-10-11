# AtomVM ESP32-C5 の TCP リソース上限レポート

この資料は、AVModbus のリソース不足テスト中に見つかった runtime 側の制約を記録します。
AVModbus の不具合と断定せずに、観測結果を AtomVM の issue へ引き継げる内容にしています。

## 概要

Seeed Studio XIAO ESP32-C5 では、上限を設けた Modbus TCP の負荷テストを繰り返し完了し、
リソースが回復することを確認できました。一方、その確認済みの条件を超えて socket への負荷を
増やすと、Elixir へ回復可能な socket resource error が返りません。観測した結果は、timer manager の
timeout 後に application が終了するか、ESP-IDF の native abort が発生するかのいずれかでした。

そのため、この実機では `:emfile`、`:enfile`、`:enobufs`、`:enomem`、`:system_limit` に対する
AVModbus の挙動を hard-limit test で確認できていません。現在の公式 runtime については、これを
platform constraint として記録します。runtime から error が返らない状態を AVModbus で回復することは
できません。project の合格範囲は、4 Client の device control で繰り返し回復することと、runtime が
`:emfile` を返す host OS 上のリソース不足テストまでとします。該当する runtime path が公式 AtomVM
image で変更された場合は、この範囲を再評価します。

## 検証環境

- board: Seeed Studio XIAO ESP32-C5
- 起動時に表示された runtime: AtomVM `0.7.0-beta.0+git.8d3e051`
- firmware image:
  `examples/hello_atomvm_modbus/firmware_images/AtomVM-esp32c5-elixir-v0.7.0-beta.0.img`
- firmware SHA-256:
  `2fcf4c8aa3c3df5c7a0c6a4be18fc437342baf6765e355ea75275ba7b89e38ad`
- transport: AtomVM の ESP32 socket driver を使った TCP loopback `127.0.0.1`
- application: production example の compile-time resource probe

socket event path の調査に使った近隣の AtomVM source checkout は
`cccd8fbcf32a333f5bb0d231a277c7511ce2499c` です。これは実際の firmware と同じ revision ではないため、
後述する address の symbol 解決には使用できません。

## `release-0.7` target の確認

AVModbus は AtomVM の
[`release-0.7`](https://github.com/atomvm/AtomVM/tree/release-0.7) branch を対象にしています。
2026-10-11 時点の head は `1f37255903c34909c06c83f866810ff9f9e43a8a`（commit date 2026-10-04）で、
インストール済み beta.0 firmware の commit `8d3e051bce9652ac1d9f52ef32b0a5f8b5fc0d65` はその祖先です。

両者の間にある 4 commit は、version metadata と MAP_EXT の key order 修正です。
`socket_driver.c`、ESP32 event queue 実装、timer manager、scheduler の timer code に変更はありません。
特に、インストール済み firmware には `e1c74523` と `dc60886f` の ESP32 socket lock 修正が
すでに含まれています。

公式の
[`v0.7.0-beta.0` release](https://github.com/atomvm/AtomVM/releases/tag/v0.7.0-beta.0) は
ESP32-C5 image と checksum を公開していますが、対応する ELF、map、debug symbol はありません。
現在の branch head を書き込んでも新しい socket path は検証できず、信頼できる symbol を得るには
build が必要です。この native failure を symbol 付きで再現して原因を特定するか、該当 path が
変更されるまでは、この制約は対象 branch に残ります。

通常の AVModbus 実機テストでは、この公式 image を引き続き使います。local build の runtime は、
対応する ELF と map を保持できるため upstream の native crash 調査には役立ちますが、release artifact
とは同一ではなく、このロードマップ項目の合格証拠には使用しません。

## 正常系の対照テスト

repository には、上限を設けた再現可能な probe を残しています。次の手順で build、flash します。

```sh
cd examples/hello_atomvm_modbus
MIX_ENV=prod mix clean
MODBUS_RESOURCE_PROBE=true MIX_ENV=prod mix atomvm.packbeam
MODBUS_RESOURCE_PROBE=true MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM0
mix atomvm.esp32.monitor --port /dev/ttyACM0
```

既定の probe は network stack を warm-up してから、4 managed Client の cycle を 3 回実行します。
各 Client は 3 request を受け付け、1 request は想定どおり `:queue_full` になります。
すべての cycle で process 数は 4 に戻りました。

| cycle | process 数（前 / peak / 後） | free heap bytes（前 / peak / 後） |
| --- | --- | --- |
| 1 | `4 / 27 / 4` | `136088 / 116784 / 135532` |
| 2 | `4 / 27 / 4` | `135368 / 116072 / 134808` |
| 3 | `4 / 27 / 4` | `134652 / 116028 / 134772` |

warm-up 後の最大 free block は 86,016 bytes を維持し、probe は
`modbus_resource_probe result=ok cycles=3` で完了しました。

これが対照条件です。負荷がある状態でも、AVModbus の bounded queue、request 完了、process cleanup、
heap recovery がすべて機能しています。

production 用に残した probe は、`MODBUS_RESOURCE_PROBE_CONNECTIONS` が `1..4` の範囲外、または
cycle 数が正でない場合、socket を開く前に fail closed します。通常の設定変更で確認済みの安全範囲を
超えないためです。hard-limit experiment には一時的な diagnostic build が必要であり、risk を
明示できるようにしています。

## Host OS のリソース不足を使った対照テスト

任意実行の Linux test は、file descriptor の soft limit を 64 にした subprocess で AVModbus を動かし、
OS が `:emfile` を返すまで loopback listener を開きます。library contract の両側を確認します。

- managed TCP Client は `{:disconnected, :emfile}` を公開し、descriptor 解放後に reconnect して
  Modbus request を完了する
- TCP Server の起動は `{:error, :emfile}` を返し、descriptor 解放後には正常に起動する

次の command で実行します。

```sh
RESOURCE_EXHAUSTION_TEST=true mix test \
  test/avmodbus/tcp_resource_exhaustion_test.exs
```

これは、runtime が resource error を返す場合に AVModbus が回復できることを示します。
ただし、ESP32 runtime は同等の error を返す前に abort するか timer service の応答を失うため、
AtomVM 実機の項目を解決する証拠にはなりません。

## リソース上限での観測結果

socket への負荷を増やすため、一時的な diagnostic variant を使用しました。board の USB CDC console が
応答しなくなり、USB の電源を抜き差ししないと回復できない場合があるため、検証後に削除しています。

### managed Client の同時起動

8 個の managed loopback Client を同時に起動しても socket resource error は返りませんでした。
AtomVM timer manager の呼び出しが 5 秒後に timeout し、その後 application が終了しました。

### socket へ順番に負荷を加えた場合

managed Client を順番に作成した場合も回復可能な resource error は得られず、有用な error を
取得する前に USB CDC console が応答しなくなりました。

より低水準の loopback socket variant では、program counter `0x4201fa15` で ESP-IDF の `abort()` に
到達しました。インストール済み firmware の directory に対応する symbol 付き ELF がないため、
この address は信頼できる形で解決できません。

どの実行でも、想定していた `:emfile`、`:enfile`、`:enobufs`、`:enomem`、`:system_limit` の
hard-limit error を Elixir は受け取りませんでした。

## 関連する socket event warning

複数の loopback socket を閉じると、次のいずれかが表示されることがあります。

```text
socket: failed to enqueue: ... to netconn_events.
socket: failed to enqueue: ... to event_queue.
```

これらの文字列はインストール済み firmware に含まれています。確認した AtomVM source では、
ESP32 socket callback は 32 entry の `netconn_events` FreeRTOS queue を使い、platform の 16 entry の
`event_queue` を介して通知します。そのため、この warning は上限のある platform event queue による
backpressure と整合します。

この warning は、process と heap が正常に回復する 3-cycle の対照テストでも発生します。
warning だけを AVModbus の resource leak の証拠とは扱いません。未解決なのは hard-limit abort と
timer manager failure です。

## 期待する動作

runtime や network stack が resource 上限に達した場合、socket の作成や接続は文書化された回復可能な
error を返す必要があります。scheduler、timer manager、既存 process、console は応答を維持し、
application が resource を解放して処理を継続するか、supervision により再起動できる状態が必要です。

## 安全に再現するための条件

- 予備の board、または物理的に操作できる board を使う。電源の抜き差しが必要になる可能性がある
- 最初に、残してある 4 Client の probe を実行し、正常系の対照結果を確認する
- production example や両方の board ではなく、一時的な diagnostic build の guard だけを変更して
  負荷を増やす
- 一方の board は通常 image のままにし、RS485 Client / Server の回復テストを続けられるようにする
- serial log 全体を保存し、書き込んだ AtomVM image と正確に対応する symbol 付き ELF も保持する
- `0x4201fa15` は対応する ELF だけで解決し、AVModbus の挙動を変更する前に失敗した native path を調べる

## 再評価する条件と手順

1. 通常の互換性テストと bounded-resource test には公式 `v0.7.0-beta.0` image を使い続ける
2. socket、event queue、timer の該当 path を変更した公式 image が公開されたら、この制約を再確認し、
   managed Client の hard-limit test を再実行する
3. upstream crash を独立して調査する場合は、対応する ELF / map を持つ一時的な runtime を build し、
   1 台の board で再現して ESP-IDF backtrace 全体の symbol を解決する。その local image を
   ロードマップの合格証拠には使用しない
4. queue saturation、lwIP allocation failure、timer service starvation のどれが native layer からの
   error 返却を妨げているかを特定する
5. 返された error を記録し、公式 image 上で AVModbus が resource を解放して reboot なしに
   request を再開できることを確認する
