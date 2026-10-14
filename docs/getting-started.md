# AVModbus のはじめ方

このページでは、AVModbus をアプリケーションに追加し、Modbus RTU で値を読み書きします。
用語が初めての場合は [Modbus の基礎](modbus-basics.md) を先に読むと理解しやすくなります。

**実機での最短手順**を探している場合は、すでに設定済みの
[XIAO ESP32-C5 チュートリアル](../examples/hello_atomvm_modbus/README.md) を利用してください。

## 1. 準備する

- Erlang / OTP と Elixir（このリポジトリの `.tool-versions` を参照）
- AtomVM `release-0.7` に対応したファームウェア
- UART を利用できる基板と、電圧が適合する RS485 トランシーバー
- 通信先の Modbus RTU Server（または Server に設定した 2 台目の基板）

配線を変更するときは電源を切ってください。トランシーバーの電源電圧と信号電圧も確認します。

## 2. ライブラリを追加する

AVModbus はまだ Hex に公開していません。ローカルに複製したリポジトリを指定します。

```elixir
defp deps do
  [
    {:avmodbus, path: "../avmodbus"},
    {:exatomvm, github: "atomvm/exatomvm", runtime: false},
    {:atomvm, "~> 0.7.0-beta.0", runtime: false}
  ]
end
```

`path:` は手元のディレクトリ構成に合わせて変更し、`mix deps.get` を実行してください。
付属サンプルの `mix.exs` には、すでに依存関係が設定されています。

## 3. UART を設定する

XIAO ESP32-C5 での設定例です。UART1、D4 / GPIO23、D5 / GPIO24 を使います。

```elixir
import Config

config :avmodbus,
  uart_peripheral: "UART1",
  uart_speed: 9_600,
  uart_tx_pin: 23,
  uart_rx_pin: 24,
  uart_data_bits: 8,
  uart_parity: :none,
  uart_stop_bits: 1
```

この例は通信速度 9,600 baud、8N1（データ 8 bit、パリティなし、ストップ 1 bit）の設定です。
基板によってピン番号は異なります。AtomVM のコンソールと同じ UART は使わないでください。

## 4. Client から読み取る

```elixir
{:ok, client} = AVModbus.Client.start_link(transport: :rtu, timeout: 1_000)

case AVModbus.Client.read_holding_registers(client, 1, 0, 2) do
  {:ok, values} -> IO.inspect(values, label: "Holding Registers")
  {:error, reason} -> IO.inspect(reason, label: "Modbus error")
end
```

`1` は通信先の Unit ID、`0` は読み始めるアドレス、`2` は読み取る個数です。
成功すると、たとえば `Holding Registers: [123, 456]` と表示されます。

Client は必要な UART を開き、通信が切れた場合の再接続も管理します。
複数の UART を使いたい場合は `start_link/1` の `serial:` オプションで個別に設定できます。

## 5. 値を書き込む

Unit ID `1` の Holding Register のアドレス `10` に、`42` を書き込みます。

```elixir
:ok = AVModbus.Client.write_single_register(client, 1, 10, 42)
```

書き込みが実行済みか不明な状態で自動再送すると、同じ操作が繰り返されるおそれがあります。
AVModbus の自動リトライは、明示された読み取り処理に限っています。

終了時は `AVModbus.Client.stop(client)` を呼びます。

## 6. Modbus TCP を使う場合

TCP では UART 設定は不要です。接続先の IP アドレスとポート番号を指定します。

```elixir
{:ok, client} =
  AVModbus.Client.start_link(
    transport: :tcp,
    host: "192.168.1.20",
    port: 502,
    timeout: 1_000
  )

AVModbus.Client.read_holding_registers(client, 1, 0, 2)
```

**注意:** Modbus TCP の通信は暗号化されません。信頼できるネットワーク内で使ってください。

## 通信できないとき

| 症状 | 確認すること |
| --- | --- |
| `{:error, :uart_pins_not_configured}` | TX / RX ピンを設定し、アプリケーションを再ビルドして `.avm` を書き込んだか |
| `{:error, :timeout}` | Server の起動、Unit ID、アドレス、通信速度・パリティが一致しているか |
| CRC エラー | GND の共通接続、配線、通信速度、パリティを確認する |
| コンソールが読めない | UART0 など、コンソールと Modbus の UART が重なっていないか |
| RS485 で応答がない | A / B の端子表記と配線、トランシーバーの電圧が正しいか |

アドレスは AVModbus では `0` から始まります。機器の説明書が `40001` のような表記を使う場合は、
[Modbus の基礎](modbus-basics.md#アドレスの注意)も確認してください。
RS485 の A / B の表記は製品によって異なります。電源を切り、機器の資料を確認してから配線を変更してください。

## 次に読む

- [実機チュートリアル](../examples/hello_atomvm_modbus/README.md)
- [開発者ガイド](development.md) — 非同期処理、Supervisor、テスト
- [動作確認済みの構成](compatibility.md)
