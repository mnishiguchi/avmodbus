# 開発者ガイド

ここでは、AVModbus を使ったアプリケーションの拡張と、変更後の検証方法をまとめます。
最初の通信確認は [はじめ方](getting-started.md) を参照してください。

## Client の設定

### TCP の同時要求と待機キュー

```elixir
{:ok, client} =
  AVModbus.Client.start_link(
    transport: :tcp,
    host: "192.168.1.20",
    port: 502,
    timeout: 1_000,
    max_pending: 4,
    max_queue: 64
  )
```

`max_pending` は送信済みで応答待ちの要求数、`max_queue` はまだ送っていない要求数の上限です。
Serial Client は同時に 1 件ずつ処理します。上限に達した場合は `{:error, :queue_full}` を返します。
待機時間もタイムアウトに含まれます。

### 非同期で要求を送る

```elixir
case AVModbus.Client.send_request(
       client,
       1,
       {:read_holding_registers, 0, 2},
       timeout: 500,
       to: self()
     ) do
  ref when is_reference(ref) ->
    receive do
      {AVModbus.Client, ^ref, result} -> result
    end

  {:error, reason} ->
    {:error, reason}
end
```

要求の受け付けは短い同期処理ですが、応答は待ちません。
受け付けた要求の結果は reference とともに一度だけ通知します。

### 読み取り処理のリトライ

```elixir
AVModbus.Client.read_holding_registers(
  client, 1, 0, 2,
  timeout: 500,
  retries: 2,
  backoff: {100, 1_000}
)
```

`retries:` を使えるのは安全に再実行できる読み取り処理です。
書き込み・診断・カスタム要求は自動リトライしません。
Modbus 例外応答や不正な応答もリトライの対象外です。

### Supervisor から起動する

```elixir
children = [
  {AVModbus.Client,
   [transport: :tcp, host: "192.168.1.20", port: 502, name: :plc_client]}
]

Supervisor.start_link(children, strategy: :one_for_one)
AVModbus.Client.read_holding_registers(:plc_client, 1, 0, 2)
```

## Serial Transport を入れ替える

`AVModbus.Serial.Transport` を実装すると、既定の AtomVM UART 以外の通信路も使用できます。
Transport には `open/1`・`read`・`write`・`close` が必要です。
`open/1` はインスタンスごとの設定を受け取ります。

```elixir
{:ok, client} =
  AVModbus.Client.start_link(
    transport: :rtu,
    serial: [peripheral: "UART2", speed: 38_400, tx: 4, rx: 5]
  )
```

RS485 の送受信方向を手動で切り替える場合は、送信完了待ちと切り替えを `write/2` 内で処理します。
UART ハンドルをアプリケーションから渡す場合は、ハンドルの終了と復旧もアプリケーションの責任です。

## Server と戻り値

`AVModbus.Server` は RTU・ASCII・TCP で共通の起動 API を提供します。

```elixir
{:ok, memory} = AVModbus.Memory.start_link()
:ok = AVModbus.Memory.put(memory, :holding_register, 10, [18, 1000, 3])

{:ok, server} =
  AVModbus.Server.start_link(
    handler: {AVModbus.Memory, memory},
    transport: :rtu,
    units: [1]
  )
```

主な戻り値は次のとおりです。

| 状況 | 戻り値 |
| --- | --- |
| 読み取り成功 | `{:ok, value}` |
| 書き込み成功 | `:ok` |
| Modbus 例外応答 | `{:error, {:exception, reason}}` |
| 要求に一致しない応答 | `{:error, {:invalid_response, pdu}}` |
| タイムアウト | `{:error, :timeout}` |
| 接続を使えない | `{:error, :closed}` |
| 待機キューが満杯 | `{:error, :queue_full}` |

Serial の Unit ID は `0..247` で、`0` は書き込みの broadcast に使います。
TCP では gateway を考慮して `0..255` を使用します。

### TCP Server を使う場合

```elixir
{:ok, server} =
  AVModbus.Server.start_link(
    handler: {AVModbus.Memory, memory},
    transport: :tcp,
    address: {192, 168, 10, 20},
    port: 502,
    connections: 4,
    max_buffer: 2_048,
    allow: [{{192, 168, 10, 0}, 24}],
    authorize: fn _role, unit_id, _request -> unit_id == 1 end
  )
```

`max_buffer` はブローカー内の未配送データだけを制限します。ソケットや処理中のデータを含む
メモリ全体の上限ではありません。接続終了時には実行中の handler を停止します。
handler に長い寿命が必要なら、別の Supervisor 管理プロセスへ委譲してください。
TCP の受信・終了処理については
[ADR 0007](https://github.com/piyopiyoex/avmodbus/blob/main/docs/adr/0007-isolate-modbus-tcp-connections.md)
に記録しています。

対象 AtomVM は Modbus/TCP Security に必要な相互認証 TLS に対応していません。
TLS を指定すると `{:error, :tls_not_supported}` を返し、暗号化なしには切り替わりません。
**TCP Server は信頼できるネットワーク内で使用し**、`address:`・`allow:`・`authorize:` と
ファイアウォールで接続元と操作を制限してください。

## テストする

通常の開発では次を実行します。

```sh
mise install
mix deps.get
mix format --check-formatted
mix test --cover
```

プロパティテストや長時間テストは必要なときだけ実行します。

```sh
FUZZ_RUNS=10000 mix test test/avmodbus/property_test.exs
SOAK_SECONDS=600 mix test --include soak test/avmodbus/soak_test.exs
AVMODBUS_PEAK_REPORT=1 mix test test/avmodbus/tcp_server_load_test.exs
```

最後のコマンドは TCP 受信中のメモリやメールボックスの**標本化した最大値**を報告します。
AtomVM 実機や OS 全体の厳密なピーク値ではありません。

### 外部の Modbus 実装とテストする

```sh
python3 -m venv /tmp/avmodbus-pymodbus
/tmp/avmodbus-pymodbus/bin/pip install 'pymodbus==3.15.0' pyserial
PYMODBUS_PYTHON=/tmp/avmodbus-pymodbus/bin/python mix test --include interop
```

`libmodbus` が使える環境では次も実行します。

```sh
LIBMODBUS_INTEROP=1 mix test --include libmodbus   test/avmodbus/libmodbus_interop_test.exs
```

外部実装とのテストはホスト上の TCP・仮想シリアル接続を使用します。
実機の RS485 通信を確認する試験ではありません。
CI の `interoperability` job の結果も、リリース前に確認してください。

## 実機で検証する

[XIAO ESP32-C5 の追加検証手順](development/hardware-tests.md) に、通信速度、
ケーブルの切断・再接続、メモリ測定、リソース回復テストの手順をまとめています。

測定した数値は
[リソース計測](https://github.com/piyopiyoex/avmodbus/blob/main/docs/development/resource-measurements.md)と
[開発記録](https://github.com/piyopiyoex/avmodbus/blob/main/docs/development/worklog.md)
に残しています。
リリース前の確認には
[チェックリスト](https://github.com/piyopiyoex/avmodbus/blob/main/docs/development/release-checklist.md)
を使ってください。
