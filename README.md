# avmodbus

`avmodbus` は、AtomVM での利用を第一目標にした Modbus ライブラリです。

- Mix / OTP application: `:avmodbus`
- Elixir namespace: `AVModbus`
- runtime dependency: なし
- 主対象: Modbus RTU / ASCII over UART / RS485、Modbus TCP
- 対象 AtomVM: `v0.7.0-beta.0`

ESP32 上で動かすサンプル application は [`examples/hello_atomvm_modbus`](examples/hello_atomvm_modbus/README.md) に分離しています。

## 特徴

- Modbus RTU / ASCII と Modbus TCP の managed client / server を提供
- Modbus TCP client / server で IPv4 と IPv6 literal address をサポート
- protocol 処理を UART や board 固有コードから分離
- 通常の BEAM 上で protocol / transport tests を実行可能
- AtomVM runtime では dependency-free
- 1 本の serial bus 上の transaction を managed process で直列化
- broadcast、adapter echo、timeout、UART reconnect を serial policy として処理
- server handler、authorization、device identification、diagnostics を transport から分離
- TCP request を transaction id で照合し、複数 request を並行処理

## 対応状況

主要な public function codes は client / server の両方向で実装済みです。

`0x01`, `0x02`, `0x03`, `0x04`, `0x05`, `0x06`, `0x07`, `0x08`, `0x0B`, `0x0C`, `0x0F`, `0x10`, `0x11`, `0x14`, `0x15`, `0x16`, `0x17`, `0x18`, `0x2B/0x0E`

custom function / MEI payload も low-level API から扱えます。

未完了の項目は [`docs/ROADMAP.md`](docs/ROADMAP.md) にまとめています。

## 基本構成

```text
Application
    |
    v
AVModbus.Client / AVModbus.Server
    |
    v
AVModbus.PDU
    |
    +---- AVModbus.RTU ------ CRC16 ----+
    |                                   |
    +---- AVModbus.ASCII ---- LRC ------+---- AVModbus.UART ---- AtomVM :uart / RS485
    |
    +---- AVModbus.TCP ------ MBAP framing
```

設計の詳細は [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) を参照してください。

## クライアントの例

```elixir
{:ok, client} = AVModbus.Client.start_link(mode: :rtu, timeout: 1_000)

{:ok, registers} =
  AVModbus.Client.read_holding_registers(client, 1, 0, 2)

:ok = AVModbus.Client.write_single_register(client, 1, 10, 42)

:ok = AVModbus.Client.close(client)
```

caller を block しない request も利用できます。

```elixir
ref =
  AVModbus.Client.send_request(
    client,
    1,
    {:read_holding_registers, 0, 2},
    timeout: 500,
    to: self()
  )

receive do
  {AVModbus.Client, ^ref, result} -> result
end
```

ASCII を使う場合は `mode: :ascii` を指定します。

Modbus TCP client は host と任意の port を指定します。

```elixir
{:ok, client} =
  AVModbus.Client.start_link(tcp: "192.168.1.20", port: 502, timeout: 1_000)
{:ok, registers} = AVModbus.Client.read_holding_registers(client, 255, 0, 2)
```

`:timeout`、`:max_pending`、`:max_queue`、`:check_unit`、`:connect_timeout`、`:backoff` で
request / connection policy を調整できます。`:timeout` の default は 1,000 ms で、request helper に
timeout を指定しない場合に使われます。
`max_pending` の default は 4、未送信 request を保持する `max_queue` の default は 64 です。
queue が満杯なら request は wire に送られず `{:error, :queue_full}` となります。
host application で無制限 queue が必要な場合だけ `max_queue: :infinity` を明示できます。

client は standard child specification を持ち、supervision tree に直接追加できます。
supervisor が返す PID または `:name` で登録した名前を、そのまま client API に渡せます。

```elixir
children = [
  {AVModbus.Client,
   [tcp: "192.168.1.20", port: 502, name: :plc_client]}
]

Supervisor.start_link(children, strategy: :one_for_one)
AVModbus.Client.read_holding_registers(:plc_client, 1, 0, 2)
```

各 request helper の最後の引数には従来の timeout millisecond、または keyword options を指定できます。
request ごとの `timeout:` は client startup の default を上書きします。
一時的な timeout / disconnect を再試行する場合は `retries:` を明示します。

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

`retry_request/4` も同じ policy の明示的な generic API として利用できます。retry の既定値は 0 で、
write、diagnostics、custom request に正の `retries:` を指定すると送信前に拒否されます。
Modbus exception や invalid response も
retry されないため、device が処理済みか不明な write を replay しません。

### Modbus/TCP Security

AtomVM 0.7 の SSL API は client connection と `verify_none` のみで、TLS server listener、peer
certificate verification、client certificate authentication を提供していません。このため
Modbus/TCP Security を安全に実装できず、`tls:` / `ssl:` を指定した client / server startup は
`{:error, :tls_not_supported}` を返して fail closed します。通常の Modbus TCP は利用できます。

必要な AtomVM capability と採用条件は ADR 0015 に記録しています。

client result と server handler result は同じ contract を使います。

- 正常な read は `{:ok, value}`、正常な write は `:ok`
- device の Modbus exception は `{:error, {:exception, reason}}`
- request と一致しない response は `{:error, {:invalid_response, pdu}}`
- transaction timeout は `{:error, :timeout}`
- connection が利用できない場合は `{:error, :closed}`
- TCP client の送信待ち queue が満杯の場合は `{:error, :queue_full}`

exception 名と wire code は `AVModbus.exception_name/1` と `AVModbus.exception_code/1` で
相互変換できます。同じ result contract のため、TCP-to-serial gateway の handler は
downstream client の result をそのまま返せます。

## サーバーの例

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

Modbus ASCII server は `transport: :ascii`、TCP server は transport option なし、または
`transport: :tcp` で起動します。`rtu: true`、`ascii: true`、`tcp: true` も指定できます。
transport-specific module を直接使う既存 API も維持しています。

Modbus TCP server は listener address、port、connection policy を指定できます。

```elixir
{:ok, server} =
  AVModbus.Server.start_link(
    handler: {AVModbus.Memory, memory},
    address: {0, 0, 0, 0},
    port: 502,
    connections: 16
  )
```

RTU、ASCII、TCP server はいずれも standard child specification を持ちます。
child options では `:handler` を指定し、supervisor が返す PID または `:name` を
`status/1`、`port/1`、`stop/1` に渡せます。

```elixir
children = [
  {AVModbus.Server,
   [
     handler: {AVModbus.Memory, memory},
     address: {0, 0, 0, 0},
     port: 502,
     name: :modbus_server
   ]}
]

Supervisor.start_link(children, strategy: :one_for_one)
AVModbus.Server.status(:modbus_server)
```

## Startup error

AVModbus の startup API は invalid configuration で raise せず、tagged error を返します。

- option list でない値は `{:error, :invalid_options}`
- unknown option は `{:error, {:invalid_option, option}}`
- invalid handler は `{:error, :invalid_handler}`
- invalid local name は `{:error, :invalid_name_option}`
- option value の範囲違反は `{:error, :invalid_<name>_option}`

validation は UART や TCP listener を開く前に完了します。これにより supervisor の start error と
direct `start_link` の error は同じ形になります。

## AtomVM サンプル

実機向けの build / flash / UART 設定は次を参照してください。

- [`examples/hello_atomvm_modbus/README.md`](examples/hello_atomvm_modbus/README.md)

## 開発

```sh
mise install
mix deps.get
mix format --check-formatted
mix test
```

property tests は通常の test suite に含まれます。case 数または実行時間を増やす場合は
次のように実行できます。

Modbus Application Protocol V1.1b3 の public function example と malformed request / response
vectors も通常の suite で client / server の両方向を検証します。

```sh
FUZZ_RUNS=10000 mix test test/avmodbus/property_test.exs
FUZZ_SECONDS=600 mix test test/avmodbus/property_test.exs
```

RTU / ASCII / TCP の managed client / server を継続運転する soak test は opt-in です。
`SOAK_SECONDS` で実行時間、`SOAK_TRANSPORT` で `all` / `rtu` / `ascii` / `tcp`、
`SOAK_INTERVAL_MS` で transaction 間隔（default: 5 ms）を指定できます。各 iteration は
write と read-back の result を照合し、終了時に process count、process memory、liveness を検証します。

```sh
SOAK_SECONDS=600 mix test --include soak test/avmodbus/soak_test.exs
SOAK_SECONDS=3600 SOAK_TRANSPORT=rtu mix test --include soak test/avmodbus/soak_test.exs
SOAK_SECONDS=3600 SOAK_TRANSPORT=ascii mix test --include soak test/avmodbus/soak_test.exs
SOAK_SECONDS=3600 SOAK_TRANSPORT=tcp mix test --include soak test/avmodbus/soak_test.exs
```

`SOAK_SECONDS` を設定しない通常の test suite では soak test を除外します。

`pymodbus` との TCP / RTU / ASCII interoperability tests は独立した Python process を peer として使います。
serial tests は test-only PTY bridge を使用し、OS package や library runtime dependency を追加しません。
専用 virtual environment を用意し、その Python を明示したときだけ実行されます。

```sh
python3 -m venv /tmp/avmodbus-pymodbus
/tmp/avmodbus-pymodbus/bin/pip install pymodbus pyserial
PYMODBUS_PYTHON=/tmp/avmodbus-pymodbus/bin/python mix test --include interop
```

`libmodbus` との双方向 TCP / RTU tests は C peer を test build directory に compile します。
RTU tests は同じ test-only PTY bridge を使用します。
header と library が `pkg-config` から見える場合だけ明示的に実行します。

```sh
LIBMODBUS_INTEROP=1 mix test --include libmodbus test/avmodbus/libmodbus_interop_test.exs
```

root package の `:atomvm` dependency は optional / `runtime: false` です。AtomVM release の supported API metadata を使った build-time validation のためだけに利用し、AVModbus の runtime dependency にはなりません。
`StreamData` も property tests 専用で、firmware の runtime dependency には含まれません。

## ドキュメント

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): 現在の設計と責務分離
- [`docs/ROADMAP.md`](docs/ROADMAP.md): 未完了の作業
- [`docs/adr`](docs/adr/README.md): 長期的に残す設計判断
- [`docs/worklog`](docs/worklog/README.md): 開発の主要マイルストーン

## 参考資料

- Modbus Application Protocol Specification V1.1b3
- Modbus Serial Line Protocol and Implementation Guide V1.02
- AtomVM UART documentation

## ライセンス

Apache-2.0
