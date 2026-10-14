# XIAO ESP32-C5 で Modbus RTU を試す

このチュートリアルでは、2 台の Seeed Studio XIAO ESP32-C5 を RS485 で接続し、
一方を Modbus RTU の Client（要求を送る側）、もう一方を Server（応答する側）として動かします。

```text
XIAO A                  XIAO B
Client                  Server
  |                        |
UART1                    UART1
  |                        |
HW-519 ===== RS485 ===== HW-519
```

最後に Client のコンソールへ次のように表示されれば成功です。

```text
modbus: registers [0]
```

Modbus の用語が初めての場合は [Modbus の基礎](../../docs/modbus-basics.md) を先に参照してください。

## 1. 必要なもの

- Seeed Studio XIAO ESP32-C5 × 2
- 3.3 V の信号電圧に対応した、自動方向切り替え式の TTL ↔ RS485 トランシーバー（検証に使用した製品: HW-519）× 2
- ブレッドボードとジャンパーワイヤー
- データ通信に対応した USB ケーブル × 2
- AtomVM ファームウェア `v0.7.0-beta.0`
- Erlang/OTP `28.5.0.7`、Elixir `1.19.6-otp-28`（リポジトリの `.tool-versions` を参照）

各 XIAO は USB から給電します。配線を変更するときは両方の USB ケーブルを外してください。

## 2. 配線する

両方の XIAO で同じように接続します。

| XIAO ESP32-C5 | HW-519 | 用途 |
| --- | --- | --- |
| `3V3` | `VCC` | トランシーバーの電源 |
| `GND` | `GND` | 共通の GND |
| `D4 / GPIO23` (`UART1 TX`) | `TXD` | XIAO から送信 |
| `D5 / GPIO24` (`UART1 RX`) | `RXD` | XIAO で受信 |

次に 2 台の HW-519 を接続します。

| Client 側 | Server 側 |
| --- | --- |
| `A+` | `A+` |
| `B-` | `B-` |
| `GND` | `GND` |

この配線は、検証に使用した **HW-519 固有のもの**です。HW-519 では、XIAO の TX を `TXD`、RX を `RXD` に接続します。
ほかのトランシーバーでは `TX → RXD` のように交差させるものもあるため、必ず使用する製品の回路図を確認してください。

重要な注意:

- `A+` と `B-` は交差させません。
- 2 台の XIAO の `GND` は共通にします。
- 各 HW-519 は接続先 XIAO の `3V3` から個別に給電します。
- 2 台の XIAO の `3V3` 同士は接続しません。
- 今回のように短い配線で試す場合、検証時は終端抵抗を追加していません。長い配線や複数台をつなぐ場合は終端抵抗の要否を確認してください。

### UART1 を使う理由

AtomVM のコンソールは UART0（D6 / GPIO11 TX、D7 / GPIO12 RX）を使います。
Modbus も同じ UART で通信すると、コンソールの文字と Modbus のフレームが混ざってしまいます。
そのため、Modbus は UART1 を D4 / GPIO23 と D5 / GPIO24 へ割り当てます。

```text
UART0: D6 / D7  ---> AtomVM console
UART1: D4 / D5  ---> AVModbus / HW-519
```

## 3. ビルド環境を準備する

リポジトリのルートからサンプルのディレクトリへ移動し、必要なツールと依存パッケージを準備します。

```sh
cd examples/hello_atomvm_modbus
mise install
mix deps.get
mix atomvm.esp32.install --version v0.7.0-beta.0
```

接続中のシリアルポートを確認します。

```sh
ls -l /dev/ttyACM*
```

以降では Server 側の基板を `/dev/ttyACM_SERVER`、Client 側を `/dev/ttyACM_CLIENT` と表記します。
実際の `/dev/ttyACM0`、`/dev/ttyACM1` などへ置き換えてください。再接続すると番号が変わる場合があります。

## 4. Server 側の基板へ書き込む

```sh
MIX_ENV=prod mix clean
MODBUS_ROLE=server MIX_ENV=prod mix atomvm.packbeam
MODBUS_ROLE=server MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM_SERVER
```

Server は `AVModbus.Memory` を使い、Unit ID `1` の Holding Register を提供します。

必要なら Server のコンソールを開き、起動を確認します。

```sh
mix atomvm.esp32.monitor --port /dev/ttyACM_SERVER
```

```text
modbus: rtu server ready for unit 1
```

確認後はモニターを終了して構いません。Server のアプリケーションはそのまま動き続けます。

## 5. Client 側の基板へ書き込む

```sh
MIX_ENV=prod mix clean
MIX_ENV=prod mix atomvm.packbeam
MIX_ENV=prod mix atomvm.esp32.flash --port /dev/ttyACM_CLIENT
```

Client のコンソールを開きます。

```sh
mix atomvm.esp32.monitor --port /dev/ttyACM_CLIENT
```

## 6. 通信を確認する

Client は 5 秒ごとに、Unit ID `1` の Holding Register をアドレス `0` から読み取ります。

```text
modbus: registers [0]
modbus: registers [0]
modbus: registers [0]
```

この表示が続けば、UART と RS485 を通じて Modbus RTU の要求と応答が正しく送受信できています。

## 7. うまくいかないとき

### `modbus: request failed :timeout`

1. Server 側の基板が起動しているか確認する
2. `A+ ↔ A+`、`B- ↔ B-`、`GND ↔ GND` を確認する
3. 両方が 9,600 baud、8N1、Unit ID `1` か確認する
4. XIAO と HW-519 の `TXD` / `RXD` がこのページの表どおりか確認する
5. ジャンパーワイヤーの接触を確認する

### RXD LED が片側だけ点滅する

Client が要求を送っていても、Server が受信できていないか、応答が戻っていない可能性があります。
まず `GND`、A / B、Server 側アプリケーションの起動を確認してください。LED の点滅だけでは通信成功とは判断しません。

### 書き込み先の基板を間違えた

同じ XIAO を 2 台接続すると、`/dev/ttyACM*` だけでは見分けにくくなります。
一度片方だけ接続してポートを確認するか、USB のシリアル番号を控えて区別してください。

### ファームウェアのダウンロードで SSL エラーが出る

[開発者向け検証手順](../../docs/development/hardware-tests.md#firmware-download-のトラブルシューティング)
に回避手順があります。


## さらに検証するとき

- [開発者向け検証手順](../../docs/development/hardware-tests.md) — 通信速度、切断・再接続、実機の負荷試験、メモリ測定
- [動作確認済みの構成](../../docs/compatibility.md) — 検証した機器と未検証の範囲
- [開発者ガイド](../../docs/development.md) — ホスト上のテスト、相互運用テスト
