# アーキテクチャ

## 方針

AVModbus は、Modbus protocol の実装と AtomVM / UART / board 固有処理を分離します。

主な方針は次のとおりです。

- protocol core は通常の BEAM 上でもテストできること
- AtomVM runtime dependency を増やさないこと
- 1 本の serial bus は 1 process が所有し、transaction を直列化すること
- RTU / ASCII で共通化できる client / server policy は共有すること
- board 固有設定は example / application 側に置くこと

## UART configuration boundary

既定の `AVModbus.UART` adapter は peripheral、TX / RX pin、baud、data bits、parity、stop bits を
firmware build 時の application configuration から取得します。これらは board wiring と deployment
profile の一部であり、managed client / server の protocol option には重複して持たせません。

runtime に UART を選択・open する必要がある application は、AtomVM `:uart` で handle を用意し、
`AVModbus.Client` または serial server の transport / handle startup entrypoint に inject できます。
この場合の close / reopen policy は application 側の責務です。実機要件から
managed reopen を保った runtime override が必要になった場合は、transport configuration として
設計し、client / server に個別の UART option を重複実装しません。

## レイヤー

```text
Application
    |
    +----------------------+----------------------+
    |                                             |
    v                                             v
AVModbus.Client                              AVModbus.Server
    |                                             |
    +----------------------+----------------------+
                           |
                           v
                      AVModbus.PDU
                           |
             +-------------+-------------+
             |             |             |
             v             v             v
       AVModbus.RTU  AVModbus.ASCII  AVModbus.TCP
       framing + CRC framing + LRC   MBAP framing
             |             |
             +------+------+
                    |
                    v
               AVModbus.UART
                    |
                    v
                AtomVM :uart
```

## プロトコルコア

`AVModbus.PDU` は function code ごとの request / response の encode / decode と validation を担当します。

RTU / ASCII / TCP の framing や UART / socket access は持ちません。これにより、protocol behavior を hardware なしでテストできます。

`AVModbus.RTU` は unit id、CRC16、frame boundary、noise recovery、silent interval で完了する frame を扱います。

`AVModbus.ASCII` は hexadecimal framing、LRC、delimiter、stream resynchronization を扱います。

`AVModbus.TCP` は MBAP header、transaction id、fragmented / concatenated TCP stream を扱います。connection lifecycle は managed TCP client または今後の server transport に委譲します。

## クライアント

`AVModbus.Client` の managed client は serial transport を所有し、同じ bus 上の request を直列化します。

主な policy:

- synchronous / asynchronous request で同じ deadline model を使用
- queue 待ち時間も timeout に含める
- RTU では送信前に 3.5-character gap を確保
- unit `0` の write を broadcast として扱い、response は読まない
- adapter echo を必要に応じて除去
- UART open / read / write failure 後は bounded exponential backoff で reopen
- protocol timeout や Modbus exception は transport failure と区別
- repeated timeout / CRC error は connection を維持し、UART read failure では pending request を一度だけ失敗させて reopen 後に transaction を再開
- positive-timeout asynchronous request は deadline arbiter が transaction result と timeout を競合解決し、queue 待ち中でも deadline-bounded exactly-once result を通知

TCP client は AtomVM / OTP 共通の active binary `:gen_tcp` socket を所有します。

- IPv4 / IPv6 literal を正規化し、address family に一致する socket を選択
- transaction id ごとに response を request と照合
- `:max_pending` まで request を並行送信し、残りは deadline を保ったまま queue
- 未送信 queue は default 64 件の `:max_queue` で制限し、saturation は `:queue_full` で通知
- fragmented / concatenated frame と out-of-order response を処理
- unit id の一致を既定で検証し、gateway compatibility 用に無効化可能
- invalid MBAP stream、peer half-close / reset、socket failure、二回連続の silent timeout 後に connection を再確立
- reconnect は bounded exponential backoff を使用
- pending / queued request は timer expiry、late response、connection drop の競合時も一度だけ result を通知

managed client は standard child specification と local `:name` registration を提供します。
supervisor が返す raw PID、registered name、従来の tagged handle は同じ public API で利用できます。
tagged handle は serial / TCP policy を caller 側で即座に識別し、raw PID / name は client process に
transport kind を問い合わせて同じ validation path に委譲します。

request helper は従来の positional timeout と、`timeout:` / `retries:` / `backoff:` の keyword
options を同じ path に正規化します。managed client startup の `:timeout` は request ごとの
既定 deadline で、省略された timeout だけに適用し、serial mailbox / TCP queue の待ち時間も
deadline に含めます。unmanaged UART transaction は従来どおり 1,000 ms を fallback にします。
0 ms timeout は、non-broadcast request かつ transmit gap が 0 の場合だけ一度の即時 attempt を許可し、
待機は行いません。
retry の既定値は 0 で、`retry_request/4` も明示的な generic
entrypoint として維持します。対象は protocol semantics が read-only と判定できる request だけで、
`:timeout` / `:closed` のみを bounded exponential backoff で再試行します。write、diagnostics、
custom request、Modbus exception、invalid response は retry せず、ambiguous write completion を
replay しません。async request は positional recipient に加えて `timeout:` / `to:` を受け付けます。

RTU、ASCII、TCP の managed server も同じ supervision contract を提供します。child options の
`:handler` を既存の `start_link(handler, options)` に委譲し、supervisor には raw PID を返します。
server の lifecycle / status API は raw PID、registered local name、従来の tagged handle を受け付けます。

`AVModbus.Server` は統一 startup facade でもあります。transport 未指定時は TCP、
`transport: :rtu | :ascii | :tcp` または対応する boolean marker で明示選択し、option を
transport-specific module に委譲します。facade は standard `{:ok, pid}` を返し、既存 module の
tagged-handle API は後方互換のため維持します。

client、server、memory の startup validation は process / UART / listener の確保前に実行し、
configuration error を `{:error, reason}` で返します。unknown option は offending option を保持し、
invalid value は `:invalid_<name>_option`、handler は `:invalid_handler` に正規化します。
supervision 専用 entrypoint も direct startup と同じ error を返します。

external interoperability は library process 外の peer で検証します。pymodbus は TCP / RTU / ASCII、
libmodbus は TCP / RTU の client / server をそれぞれ AVModbus の反対 role と接続し、read / write、
mask write、read-write multiple、exception response を wire 経由で確認します。serial tests は
test-only Python PTY bridge と injected transport adapter を使います。peer dependency は runtime や
Hex package に含めず、明示的な test tag / environment variable がある場合だけ起動します。
custom function と generic MEI は `pymodbus` の registered custom PDU を専用 peer mode で使い、
TCP / RTU / ASCII の双方向 wire behavior を検証します。generic MEI の登録は `pymodbus` の built-in
Device Identification dispatcher を置き換えるため、standard function の peer mode とは process を
分離します。RTU custom PDU は test vector の fixed frame size を peer に明示します。

Modbus/TCP Security は fail-closed boundary とします。AtomVM 0.7 の `:ssl` は client-side
`connect/3` だけを公開し、server listen / accept と mutual certificate verification を提供しません。
`tls:` / `ssl:` option は client、unified server、TCP server のすべてで
`{:error, :tls_not_supported}` を返します。`verify_none` の client-only TLS を Modbus/TCP Security と
して提供することはしません。enablement criteria は ADR 0015 に記録します。

client が返す result と server handler が返す result は共通です。Modbus exception は
`{:error, {:exception, reason}}`、request に一致しない response は
`{:error, {:invalid_response, pdu}}` に統一し、gateway が downstream client result を
変換せず返せるようにします。

low-level transaction API は、host tests や application が UART ownership を明示的に管理する場合のために残しています。

## サーバー

`AVModbus.Server` は transport-independent な request processor です。

application handler は次のどちらかで指定できます。

- `fn unit_id, request -> result end`
- `{module, argument}` と `handle_request/3`

serial server は framing と UART lifecycle を担当し、request semantics は `AVModbus.Server` に委譲します。
RTU の silent interval を必要とする ambiguous / corrupted input と、known-length frame の連続入力を
区別し、RTU / ASCII とも fragmented input と line noise の後に stream synchronization を維持します。

主な server policy:

- configured unit id の filtering
- broadcast write の no-response semantics
- diagnostics / event counter / event log の line-level state
- handler を monitored process で隔離し、timeout / crash を `server_device_failure` に変換
- authorization callback
- Read Device Identification の built-in response
- UART disconnect 後の reopen / backoff
- RTU / ASCII で request dispatch、handler policy、recovery policy を共有

TCP server は listener と connection admission を managed process で所有し、各 connection を独立した process で処理します。

- 同じ connection の request は wire order で応答し、異なる connection は並行処理
- active binary socket の ownership transfer 中に届いた message も connection process に転送
- connection 上限では、最も多く connection を保持する address group の最古 connection を優先して evict
- address / network prefix allowlist、request 完了基準の idle timeout を提供
- invalid MBAP length では connection を閉じ、foreign protocol frame は破棄
- authorization、device identification、handler timeout は serial server と同じ core policy を使用
- 複数 managed client、connection ごとの pipelined request、処理時間の異なる handler を組み合わせた load test で connection 間の並行性と result correlation を検証

## メモリハンドラー

`AVModbus.Memory` は small-device 向けの sparse in-memory data model です。

- coils
- discrete inputs
- holding registers
- input registers
- file records
- FIFO

全 address space を事前確保せず、明示的に書き込まれた値だけを保持します。

## AtomVM との境界

`AVModbus.UART` は AtomVM `:uart` を包む薄い adapter です。

GPIO、baud rate、parity、board pinout、firmware install、polling loop は library の責務ではありません。これらは application または `examples/hello_atomvm_modbus` 側で設定します。

## 現在の制約

- 主対象は serial Modbus RTU / ASCII
- Modbus TCP は MBAP codec と managed client / server を実装済み
- RTU-over-TCP は未実装
- test-only duplex transport と TCP loopback を使う opt-in host soak harness を提供済み
- real RS485 peer と AtomVM device 上での長時間 interoperability / soak test は未完了
- retry は write の重複実行を避けるため、一般的な自動 retry としては提供していない
- Modbus/TCP Security は AtomVM に mutual-authenticated TLS client / server API がないため未実装
