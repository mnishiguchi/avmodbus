# AVModbus 互換性表

この表は **確認済みの組み合わせと未検証の組み合わせを区別**するためのものです。
新しい hardware を所有する必要はなく、実際に動作を確認したときだけ行を追加します。

## 記録済みの実績

| Client / Server | Transport / peer | Device / adapter | Firmware / peer version | 根拠 | 状態 |
| --- | --- | --- | --- | --- | --- |
| ESP32-C5 / ESP32-C5 | RTU / RS485 | Seeed Studio XIAO ESP32-C5 × 2, HW-519 × 2 | AtomVM `v0.7.0-beta.0+git.8d3e051` | 2026-10-10 の 5 分 run（1,623 requests, 0 failures）と後続の workflow | Tested in documented setup |
| AVModbus ↔ `pymodbus` | TCP / RTU / ASCII | Host TCP / test-only PTY | `pymodbus` 3.15.0 | opt-in interoperability tests、`docs/worklog/README.md` | Host-tested |
| AVModbus ↔ `libmodbus` | TCP / RTU | Host TCP / test-only PTY | `libmodbus` 3.1.11（記録された host baseline） | opt-in interoperability tests、`docs/worklog/README.md` | Host-tested |

*実機の行は既存記録を転記したものです。外部 peer は 2026-10-14 に固定 seed 2 種類で
local suite を再実行しました。GitHub Actions 上での通過は別途確認します。*

## 未検証 / 継続課題

| 構成 | 理由 / 次の確認 | 状態 |
| --- | --- | --- |
| Other RS485 transceivers and USB-RS485 adapters | DE/RE direction switching, echo, baud/parity | Not tested |
| Commercial Modbus RTU devices | Actual device exception / timeout / interoperability | Not tested |
| Multi-drop RS485 with three or more nodes | Address filtering, bus contention, termination/bias | Not tested |
| Other AtomVM targets or newer release images | UART/socket APIs and device resource ceilings | Not tested |

## 検証記録の項目

新しい実績を追加するときは少なくとも以下を記録します。

- 日付と検証した commit、AtomVM の正確な tag または commit SHA
- MCU / board、transceiver または adapter、配線 / termination、bus topology
- RTU の baud / parity / stop bits（または TCP network configuration）
- Client / Server の実装と version
- Function Code、実行時間、成功 / 失敗 request 数、timeout / recovery 結果
- 利用可能なら artifact size、heap / process の観測値
- 再現用の log / command と既知の制約

**Policy:** `Host-tested` は embedded hardware validation を意味せず、`Not tested` は unsupported を意味しません。
