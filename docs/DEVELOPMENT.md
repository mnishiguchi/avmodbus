# 開発者ガイド

このページは、AVModbus を application へ組み込む人、library の変更や検証を行う人向けです。
初めて request を送る場合は [Getting Started](GETTING_STARTED.md) から始めてください。

## Client の管理範囲

`AVModbus.Client.start_link/1` で起動した Client は UART または TCP connection を所有し、通信状態を管理します。
open 済み transport handle を渡す injected mode では ownership は呼び出し側に残り、Client は停止時や
transport failure 時にその handle を close / reopen しません。

- serial bus 上の request を順番に処理
- serial / TCP の送信待ち queue を `max_queue` で制限
- request ごとの timeout と全体の deadline を管理
- UART close 後の reopen / backoff
- TCP reconnect と transaction ID による response 照合
- TCP の同時送信数を `max_pending` で制限

### 非同期 request

transaction の完了を待たず request を送れます。Client が request を受け付けると reference を返し、
完了時に同じ reference を含む message を 1 回送ります。queue が満杯、または Client を利用できない場合は
reference の代わりに `{:error, reason}` をその場で返します。

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

受付は短い synchronous call ですが、wire response は待ちません。これにより producer が一方的に
Client mailbox と deadline helper を増やすことを防ぎ、`max_queue` を backpressure 境界として使えます。

### timeout と retry

Client 起動時の `timeout:` は request の既定 timeout です。request ごとの値が優先されます。

```elixir
AVModbus.Client.read_holding_registers(
  :plc_client,
  1,
  0,
  2,
  timeout: 500,
  retries: 2,
  backoff: {100, 1_000}
)
```

retry は明示した読み取り request にだけ適用されます。write、diagnostics、custom request は、
同じ操作の重複を避けるため正の `retries:` を受け付けません。Modbus exception や不正な response も retry しません。

### Serial / TCP の queue

Serial Client は active transaction を 1 件に制限し、残りを `max_queue` まで待機させます。
TCP Client は次のように、wire 上の request 数も `max_pending` で制限します。

```elixir
{:ok, client} =
  AVModbus.Client.start_link(
    transport: :tcp,
    host: "192.168.1.20",
    port: 502,
    timeout: 1_000,
    max_pending: 4,
    max_queue: 64,
    connect_timeout: 1_000,
    backoff: {100, 5_000}
  )
```

wire 上で応答待ちにできる request 数は `max_pending`、まだ送信していない request 数は
`max_queue` で制限します。queue が満杯の場合は、request を送らず `{:error, :queue_full}` を返します。

### supervision tree

Client は standard child specification を持ちます。

```elixir
children = [
  {AVModbus.Client,
   [
     transport: :tcp,
     host: "192.168.1.20",
     port: 502,
     name: :plc_client
   ]}
]

Supervisor.start_link(children, strategy: :one_for_one)
AVModbus.Client.read_holding_registers(:plc_client, 1, 0, 2)
```

### Serial transport と instance 設定

`AVModbus.Serial.Transport` は serial adapter の `open` / `read` / `write` / `close` contract を定義します。
既定の `AVModbus.UART` は `serial:` で UART 設定を instance ごとに受け取ります。

```elixir
{:ok, client} =
  AVModbus.Client.start_link(
    transport: :rtu,
    serial: [peripheral: "UART2", speed: 38_400, tx: 4, rx: 5]
  )
```

custom adapter は `@behaviour AVModbus.Serial.Transport` を指定し、instance 設定を受け取る
`open/1` を実装します。設定を使わない adapter も空 list を受け付けてください。
manual DE / RE adapter では、UART の送信完了待ちと受信方向への切り替えを終えてから
`write/2` を返してください。Client / Server は GPIO direction を直接操作しません。

## 戻り値の形式

Client と Server handler は同じ形式を使います。

| 状況 | 戻り値 |
| --- | --- |
| 読み取り成功 | `{:ok, value}` |
| 書き込み成功 | `:ok` |
| Modbus exception | `{:error, {:exception, reason}}` |
| request と一致しない response | `{:error, {:invalid_response, pdu}}` |
| timeout | `{:error, :timeout}` |
| connection を利用できない | `{:error, :closed}` |
| Serial / TCP の送信待ち queue が満杯 | `{:error, :queue_full}` |

Serial の Unit ID は `0..247` です。`0` は write broadcast にだけ利用でき、個別 Server は
`1..247` を使います。TCP の Unit Identifier は gateway routing を含む `0..255` として扱います。

`AVModbus.exception_name/1` と `AVModbus.exception_code/1` で exception 名と wire code を変換できます。

## Server

### 共通 facade

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

Modbus ASCII は `transport: :ascii`、Modbus TCP は `transport: :tcp` を指定します。

### TCP Server

```elixir
{:ok, server} =
  AVModbus.Server.start_link(
    handler: {AVModbus.Memory, memory},
    transport: :tcp,
    address: {192, 168, 10, 20},
    port: 502,
    connections: 16,
    max_buffer: 2_048,
    allow: [{{192, 168, 10, 0}, 24}],
    authorize: fn _role, unit_id, _request -> unit_id == 1 end
  )
```

Server も supervision tree から起動でき、登録名を `status/1`、`port/1`、`stop/1` に渡せます。
`max_buffer` は slow handler 中に、socket owner の broker が protocol worker へまだ渡していない binary の
上限です。Modbus TCP ADU の最大長を保持できる 260 bytes 以上を指定し、単一受信 chunk または broker 内の
蓄積が超過した connection は閉じます。active socket mailbox、worker が処理中の chunk / frame remainder、
OS / runtime socket buffer はこの値に含まれないため、connection 全体の厳密な memory 上限ではありません。
connection を閉じるときは、その connection で実行中の isolated handler も `:kill` で停止します。
これは handler が `Process.flag(:trap_exit, true)` を設定していても適用する lifecycle contract です。
handler に connection より長い寿命が必要な場合は、handler から別の supervised process へ処理を委譲してください。

## TCP shutdown と故障時の cleanup

接続 broker は socket handover 待機中でも stop request を処理します。listener は通常の stop / eviction
で broker の停止を待ちますが、応答しない broker は 1 秒後にまとめて `:kill` し、さらに最大 100 ms だけ
終了通知を待ちます。listener の応答を無期限に止めず、server stop 全体でこの待機 budget を共有します。

正常な切断では broker が実行中の isolated handler を停止します。broker が外部から `:kill` された場合も、
listener が登録済み handler を終了させる fallback を持ちます。この所有権監視は listener が生存している
範囲の保証であり、VM 全体の異常終了や listener の強制 `:kill` までは保証しません。

Host の回帰テストには forced broker death、停止不能 broker、rapid connect/disconnect と TCP burst が含まれます。
TCP burst の broker / protocol worker process mailbox と memory を標本化するには次を実行します。

```sh
AVMODBUS_PEAK_REPORT=1 mix test test/avmodbus/tcp_server_load_test.exs
```

報告する値は polling で見えた **sampled maximum** です。OS socket buffer、worker、handler、
仮想マシン全体の厳密な peak を意味しません。実機では既存の resource probe / health telemetry と併せ、
同一 firmware と負荷条件で比較してください。

2026-10-14 の host baseline では、最初の handler を停止したまま 160 個の 12-byte ADU を 1 ms 間隔で送り、
6 run すべてで broker memory 16,768 bytes / heap 1,598 words、worker memory 2,744 bytes / heap 233 words、
sampled mailbox は broker 0–1 / worker 0 でした。この値は host BEAM と当該負荷の比較基準であり、
AtomVM や別の socket chunking に対する上限ではありません。

## 起動時の設定チェック

起動 API は不正な設定で例外を発生させず、tagged error を返します。

- option list でない: `{:error, :invalid_options}`
- 不明な option: `{:error, {:invalid_option, option}}`
- 不正な handler: `{:error, :invalid_handler}`
- 不正な登録名: `{:error, :invalid_name_option}`
- option の範囲違反: `{:error, :invalid_<name>_option}`

UART、socket、listener などの resource を確保する前に設定を検査します。

## Modbus/TCP Security

対象の AtomVM 0.7 runtime は、Modbus/TCP Security に必要な TLS Server、peer certificate verification、
client certificate authentication をすべて提供していません。`tls:` / `ssl:` を指定すると
`{:error, :tls_not_supported}` を返し、暗号化なしへ自動的に切り替えません。

暗号化されていない Modbus TCP Server を public network や untrusted LAN の全 interface に公開しないでください。

- `address:` は device の trusted interface に割り当てた IP address を指定する
- `allow:` で接続元 address または network prefix を制限する
- `authorize:` で許可する Unit ID と request を application policy に合わせて制限する
- OS / router firewall でも TCP port 502 への接続元を同じ subnet または管理 host に限定する
- untrusted network を通す場合は、相互認証を提供する VPN または secure gateway の内側へ配置する

`connections:`、`max_buffer:`、`idle:`、`handler_timeout:` は防御境界です。Internet へ直接公開できる
authentication の代替ではありません。connection churn は load / resource probe で確認します。

詳細は [ADR 0015](adr/0015-fail-closed-without-mutual-tls.md) を参照してください。

## 通常の test suite

```sh
mise install
mix deps.get
mix format --check-formatted
mix test
```

Modbus Application Protocol V1.1b3 の function example、境界値、不正 frame、property test を含みます。
coverage gate は production module を対象に 80% 以上とし、test 専用の Duplex / PTY transport は
集計から除外します。

```sh
mix test --cover
```

### Property test を長く実行する

```sh
FUZZ_RUNS=10000 mix test test/avmodbus/property_test.exs
FUZZ_SECONDS=600 mix test test/avmodbus/property_test.exs
```

## Soak test

RTU / ASCII / TCP の Client / Server を連続運転し、read-back、process 数、process memory、liveness を確認します。

```sh
SOAK_SECONDS=600 mix test --include soak test/avmodbus/soak_test.exs
SOAK_SECONDS=3600 SOAK_TRANSPORT=rtu mix test --include soak test/avmodbus/soak_test.exs
SOAK_SECONDS=3600 SOAK_TRANSPORT=ascii mix test --include soak test/avmodbus/soak_test.exs
SOAK_SECONDS=3600 SOAK_TRANSPORT=tcp mix test --include soak test/avmodbus/soak_test.exs
```

`SOAK_INTERVAL_MS` で transaction 間隔を指定できます。設定しない通常の test suite では除外されます。

## `pymodbus` との相互運用テスト

独立した Python process を peer として、TCP / RTU / ASCII を双方向に検証します。
serial test は test 専用 PTY bridge を使います。

```sh
python3 -m venv /tmp/avmodbus-pymodbus
/tmp/avmodbus-pymodbus/bin/pip install 'pymodbus==3.15.0' pyserial
PYMODBUS_PYTHON=/tmp/avmodbus-pymodbus/bin/python mix test --include interop
```

## `libmodbus` との相互運用テスト

```sh
LIBMODBUS_INTEROP=1 mix test --include libmodbus \
  test/avmodbus/libmodbus_interop_test.exs
```

C peer は test build directory に compile されます。RTU test は test 専用 PTY bridge を使います。
CI の `interoperability` job では `pymodbus==3.15.0` と `libmodbus-dev` を用意し、
両方の peer を使った host test を実行します。実 RS485 機材との相互運用テストは含みません。

## 実機の高度な検証

次の手順と compile-time option は
[XIAO ESP32-C5 sample の「開発者向け検証」](../examples/hello_atomvm_modbus/README.md#開発者向け検証) にあります。

- baud rate と cable disconnect / reconnect
- memory footprint と health telemetry
- resource recovery probe
- 20-step real RS485 workflow probe
- artifact size budget

測定結果は [Memory footprint](MEMORY_FOOTPRINT.md)、[Artifact size](ARTIFACT_SIZE.md)、
[Worklog](worklog/README.md) に記録しています。

## Build-time dependency

root package の `:atomvm` dependency は optional / `runtime: false` です。AtomVM supported API metadata を
使った build-time validation のためだけに利用します。`StreamData` も property test 専用です。
AVModbus の firmware runtime dependency には含まれません。
