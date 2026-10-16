# AVModbus

AVModbus は、**AtomVM で Modbus 通信を扱うための Elixir ライブラリ**です。
Modbus RTU・ASCII・TCP に対応し、データを読み取る Client と、要求に応答する Server の両方を作れます。

たとえば、ESP32-C5 と RS485 モジュールを使ってセンサーの値を読んだり、
ほかの機器から読み取れる Holding Register を用意したりできます。

> **公開前の開発版です。** まだ Hex には公開していません。現在は AtomVM `release-0.7` を対象に開発しています。

## まず動かしてみる

初めて Modbus を使う場合は、次の順に読むと進めやすいです。

1. [Modbus の基礎](docs/modbus-basics.md) — RS485 との違いや基本用語
2. [はじめ方](docs/getting-started.md) — ライブラリの追加と読み書き
3. [XIAO ESP32-C5 実機チュートリアル](examples/hello_atomvm_modbus/README.md) — 2 台の基板で RS485 通信

## 対応している機能

- Modbus RTU・ASCII・TCP の Client / Server
- Coil・Discrete Input・Input Register・Holding Register の読み取りと、書き込み可能な領域への書き込み
- 主な標準 Function Code、タイムアウト、再接続、読み取り処理のリトライ
- AtomVM UART と、ほかの通信手段に差し替えられる Serial Transport
- Elixir の Supervisor からの起動

対応状況と実機で確認した構成は [互換性表](docs/compatibility.md) に記録しています。

## 実験: AVModbus 上の distributed Erlang

AVModbus の custom Function Code `100` を transport primitive として使い、AtomVM の
`serial_dist` を Modbus RTU / RS485 上で動かすことに成功しています。2 台の XIAO
ESP32-C5 で genuine distribution handshake、remote process の ping / pong、512-byte
payload の連続往復、115,200 baud での 4 KiB payload の 1 往復、再起動後の再同期を確認しました。

これは [独立した実験用サンプル](examples/hello_atomvm_modbus_disterl/README.md) の成果です。
AVModbus が distributed Erlang carrier を public API として提供している、または production
用途をサポートしているという意味ではありません。polling、sequence / ACK、session recovery、
virtual UART adapter はサンプル内にあり、`lib/avmodbus/` は変更していません。

- [実験の構成と再現手順](examples/hello_atomvm_modbus_disterl/README.md)
- [実機試験と測定結果](examples/hello_atomvm_modbus_disterl/docs/worklog/README.md)
- [既知の制約](https://github.com/piyopiyoex/avmodbus/blob/main/examples/hello_atomvm_modbus_disterl/docs/limitations.md)

## Client の例

Unit ID `1` の Holding Register を、アドレス `0` から 2 個読み取ります。

```elixir
{:ok, client} = AVModbus.Client.start_link(transport: :rtu, timeout: 1_000)

{:ok, values} = AVModbus.Client.read_holding_registers(client, 1, 0, 2)
IO.inspect(values, label: "Holding Registers")
```

RTU を使う場合は、先に UART のピンや通信速度を設定してください。
詳しい設定方法は [はじめ方](docs/getting-started.md) にあります。

## Server の例

```elixir
{:ok, memory} = AVModbus.Memory.start_link()
:ok = AVModbus.Memory.put(memory, :holding_register, 0, [123, 456])

{:ok, server} =
  AVModbus.Server.start_link(
    handler: {AVModbus.Memory, memory},
    transport: :rtu,
    units: [1]
  )
```

この例でも、実機では UART 設定が必要です。

## 開発に参加する

```sh
mise install
mix deps.get
mix format --check-formatted
mix test
```

設計や検証結果を調べる場合は、次の資料を参照してください。

- [ドキュメント一覧と更新方針](https://github.com/piyopiyoex/avmodbus/blob/main/docs/README.md) — 資料の分類とメンテナンス方法
- [開発者ガイド](docs/development.md) — テストと高度な使い方
- [アーキテクチャ](docs/architecture.md) — 内部構造と設計方針
- [開発記録](https://github.com/piyopiyoex/avmodbus/blob/main/docs/development/worklog.md) /
  [設計判断](https://github.com/piyopiyoex/avmodbus/blob/main/docs/adr/README.md) — 実験結果と判断理由
- [リリース前チェックリスト](https://github.com/piyopiyoex/avmodbus/blob/main/docs/development/release-checklist.md)

## 動作環境と注意点

実機で確認した構成は、XIAO ESP32-C5、HW-519 RS485 モジュール、
AtomVM `v0.7.0-beta.0+git.8d3e051` です。ライブラリ自体に実行時依存パッケージはありません。

Modbus TCP の暗号化・相互認証には未対応です。暗号化なしに自動で切り替わることはありませんが、
**TCP Server は信頼できるネットワーク内で使用してください**。
また、ESP32-C5 の TCP 接続数には実機で確認した範囲があります。
詳細は
[既知の制約](https://github.com/piyopiyoex/avmodbus/blob/main/docs/limitations.md)
を参照してください。

## ライセンス

Apache-2.0
