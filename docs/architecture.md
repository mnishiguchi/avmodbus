# アーキテクチャ

このページは、AVModbus の内部構造を理解したい開発者向けです。
最初に使う場合は [はじめ方](getting-started.md) を参照してください。

## 基本方針

**Modbus の通信ルールと、UART や TCP でデータを運ぶ処理を分ける**ことを重視しています。
そのため、通信フレームの処理は普通の BEAM 上でもテストでき、実機固有の処理は入れ替えられます。

```text
Application
  |-- AVModbus.Client / AVModbus.Server
  |     `-- AVModbus.PDU（読み書きする内容）
  |           |-- AVModbus.RTU   （CRC とフレーム）
  |           |-- AVModbus.ASCII （LRC とフレーム）
  |           `-- AVModbus.TCP   （MBAP とフレーム）
  |
  |-- Serial Transport --> AVModbus.UART --> AtomVM :uart
  `-- TCP socket ------------------------> :gen_tcp
```

`AVModbus.PDU` は Function Code ごとのエンコード・デコードを担当します。
RTU・ASCII・TCP の各モジュールは、通信方式ごとのフレームを扱います。
Client / Server が接続と要求の処理を管理します。

## UART と RS485

`AVModbus.Serial.Transport` は `open/1`・`read`・`write`・`close` の共通インターフェースです。
既定の `AVModbus.UART` は AtomVM の UART を使います。
UART 番号、ピン、通信速度はアプリケーション設定から読み、`serial:` で接続ごとに上書きできます。

AtomVM 0.7 / ESP32-C5 では、UART の読み取りと次の読み取りの間にデータを失う場合がありました。
そのため、専用プロセスで継続して読み取り、受信データを上限 2,048 byte のバッファーに渡します。
RX idle timeout の既定値は、実機で確認した **20 ms** です。
Modbus RTU の送信間隔やフレーム判定の待ち時間とは別の設定です。

UART の読み取りに失敗した場合は、古い受信データを捨ててエラーを通知します。
Client / Server が UART を管理していれば再接続を試みます。
一方、アプリケーションから UART ハンドルを渡した場合は、開閉と復旧をアプリケーションが担当します。

方向切り替えが必要な RS485 モジュールでは、その処理を Transport の `write/2` に含めます。
Client / Server 自体は GPIO を操作しません。
判断理由は
[ADR 0019](https://github.com/piyopiyoex/avmodbus/blob/main/docs/adr/0019-keep-uart-configuration-at-transport-boundary.md)
にあります。

## Client の管理

- Serial では、1 本の通信路で要求を **順番に 1 件ずつ**処理します。
- TCP では Transaction ID を使い、複数の要求と応答を対応付けます。
- 待機キューには上限があり、満杯の場合は `{:error, :queue_full}` を返します。
- タイムアウトにはキューでの待ち時間も含めます。非同期要求も結果を一度だけ通知します。
- 書き込みの二重実行を避けるため、自動リトライは明示された読み取り処理だけに限定します。
- 通信が切れた場合は、必要に応じて再接続します。

詳しい動作と API は [開発者ガイド](development.md) を参照してください。

## Server の管理

Serial Server は受信したフレームを解釈し、`AVModbus.Server` に処理を渡します。
TCP Server は接続ごとに処理を分け、遅い Client が別の接続に与える影響を抑えます。

TCP の `max_buffer`（既定 2,048 byte）は **受信ブローカーがまだ渡していないデータの上限**です。
ソケットの受信待ちや処理中のデータ、AtomVM 側のバッファーを含めた、
接続全体のメモリ使用量の上限ではありません。

接続を閉じる際は、処理中の handler も終了させます。ブローカーが強制終了した場合も、
listener が生きていれば handler を終了するための代替処理を行います。
終了待ちは無期限にならないよう制限しています。
詳細は
[ADR 0007](https://github.com/piyopiyoex/avmodbus/blob/main/docs/adr/0007-isolate-modbus-tcp-connections.md)
に残しています。

## AtomVM での制約

- Modbus/TCP Security に必要な相互認証 TLS が使えないため、TLS の指定はエラーになります。
- ESP32-C5 では TCP の負荷を増やしすぎると、ランタイムが応答しなくなる現象を確認しています。
- RTU の既定タイミングは検証済みの UART / RS485 構成に基づきます。

これらの詳細は
[既知の TCP 制約](https://github.com/piyopiyoex/avmodbus/blob/main/docs/limitations.md) と
[開発記録](https://github.com/piyopiyoex/avmodbus/blob/main/docs/development/worklog.md)
を参照してください。
