# アーキテクチャ

この資料は、AVModbus の内部構造を変更する開発者向けです。最初に利用する場合は
[Getting Started](GETTING_STARTED.md) を参照してください。API 名や protocol 固有の用語は原語を維持し、
責務と判断理由を日本語で説明します。

## 方針

AVModbus は、Modbus protocol の実装と AtomVM / UART / board 固有処理を分離します。

主な方針は次のとおりです。

- protocol core は通常の BEAM 上でもテストできること
- AtomVM の実行時 dependency を増やさないこと
- 1 本の serial bus は 1 process が所有し、transaction を順番に処理すること
- RTU / ASCII で共通化できる Client / Server の方針は共有すること
- board 固有設定は example / application 側に置くこと

## UART 設定の境界

`AVModbus.Serial.Transport` は `open` / `read` / `write` / `close` の contract を定義し、protocol core と
UART / custom hardware を分離します。既定の `AVModbus.UART` adapter は peripheral、TX / RX pin、baud、
data bits、parity、stop bits を firmware build 時の application configuration から取得します。
transport の `open/1` は常に instance 設定の keyword list を受け取ります。
Client / Server の `serial:` option で instance ごとに上書きでき、同じ firmware から複数 bus を異なる
設定で起動できます。RTU の既定 frame gap と低 baud で必要な receive silence も、その instance の
`speed` から計算します。

AtomVM の `uart:read/2` は、次の read を開始するまでに届いた byte を保持しない場合があります。
既定 adapter は専用 reader で UART を継続して読み、隣接 chunk を UART 固有の RX idle timeout まで
drain してから 2,048-byte 上限の broker へ渡します。これは `modbus_silence_ms` とは独立した
`uart_rx_idle_timeout_ms`（instance option は `rx_idle_timeout:`）で、RTU / ASCII の frame boundary は
上位の codec が判断します。AtomVM 0.7 / ESP32-C5 の実機では即時転送時に長い request の byte 欠落を
再現したため、既定 20 ms を維持します。別の UART driver や高 baud rate で短縮する場合は実機で
fragmentation と連続 request を検証します。

Client / Server の read timeout は broker 上の待機だけを取り消し、UART の継続受信は止めません。
broker は reader を監視し、buffer overflow、UART error、reader の終了を transport failure として返します。
transport failure は terminal state です。broker は残っていた buffer を破棄し、失敗後に届く data を無視して、
待機中および以後の read へ最初の error を返します。read timeout と failure が競合して local timeout が先に
確定した場合も、次の read では記録済みの terminal error を返します。managed lifecycle は失敗した handle を
close / reopen します。

application が UART handle を直接管理する injected mode では、AtomVM `:uart` で handle を用意し、
`AVModbus.Client` または serial server の transport / handle startup entrypoint に inject できます。
Client / Server はその handle を close / reopen せず、owner process と recovery policy は application 側の
責務です。通常の managed mode では Client / Server process が `open/1` を呼び、同じ process の終了、
transport failure、再接続と UART lifecycle を一貫して管理します。

manual DE / RE を使う adapter は、送信完了待ちと direction 切り替えを `write/2` 内で行います。
Client / Server は GPIO を直接操作せず、将来 native RS485 mode が利用可能になっても同じ contract を保ちます。

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
request と response の frame accumulation は最大 256 bytes に制限し、unknown-length response も超過時に
`:frame_too_long` として停止します。raw UART broker の 2,048-byte 上限とは別の protocol invariant です。

`AVModbus.ASCII` は hexadecimal framing、LRC、delimiter、stream resynchronization を扱います。

`AVModbus.TCP` は MBAP header、transaction id、fragmented / concatenated TCP stream を扱います。
connection lifecycle は、AVModbus が接続状態を管理する TCP Client / Server が担当します。

## クライアント

`AVModbus.Client` の managed client は serial transport を所有し、同じ bus 上の request を直列化します。

主な policy:

- synchronous / asynchronous request で同じ deadline model を使用
- queue 待ち時間も timeout に含める
- transaction worker は常に 1 process とし、待機 request は既定 64 件の `:max_queue` で制限
- async request は短い synchronous admission で受け付け、saturation は `:queue_full` を即時返却
- deadline arbiter は受付済みの active / queued request にだけ作成し、process 数も queue 境界内に保つ
- transport failure は active / queued request を一度ずつ `:closed` で完了
- RTU では送信前に、19,200 baud 以下なら 3.5 character、より高速なら 1.75 ms の gap を確保
- built-in profile では baud rate から gap を算出し、`:modbus_rtu_gap_ms` はその下限として適用
- automatic-direction hardware が追加 margin を必要とする場合は、計算値より大きい compile-time 下限を設定
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
- 未送信 queue は default 64 件の `:max_queue` で制限し、async admission でも saturation は
  `:queue_full` を即時返却
- fragmented / concatenated frame と out-of-order response を処理
- unit id の一致を既定で検証し、gateway compatibility 用に無効化可能
- invalid MBAP stream、peer half-close / reset、socket failure、二回連続の silent timeout 後に connection を再確立
- reconnect は bounded exponential backoff を使用
- pending / queued request は timer expiry、late response、connection drop の競合時も一度だけ result を通知

managed client は standard child specification と local `:name` registration を提供します。
supervisor が返す raw PID、registered name、従来の tagged handle は同じ public API で利用できます。
tagged handle は opaque 型で、serial / TCP policy を library が即座に識別します。raw PID / name は client process に
transport kind を問い合わせて同じ validation path に委譲します。

request helper は `timeout:` / `retries:` / `backoff:` の keyword options を受け付けます。
device identification helper の category も `category:` で指定し、既定値は `:basic` です。
managed client startup の `:timeout` は request ごとの既定 deadline で、省略された timeout
だけに適用し、serial mailbox / TCP queue の待ち時間も deadline に含めます。unmanaged UART
transaction は 1,000 ms を fallback にします。
0 ms timeout は、non-broadcast request かつ transmit gap が 0 の場合だけ一度の即時 attempt を許可し、
待機は行いません。
retry の既定値は 0 で、`retry_request/4` も明示的な generic
entrypoint として維持します。対象は protocol semantics が read-only と判定できる request だけで、
`:timeout` / `:closed` のみを bounded exponential backoff で再試行します。write、diagnostics、
custom request、Modbus exception、invalid response は retry せず、ambiguous write completion を
replay しません。async request は `timeout:` / `to:` を受け付けます。

RTU、ASCII、TCP の managed server も同じ supervision contract を提供します。child options の
`:handler` を既存の `start_link(handler, options)` に委譲します。facade と transport-specific module の
どちらも `{:ok, pid}` を返し、server の lifecycle / status API は raw PID または registered local name を
受け付けます。

`AVModbus.Client` と `AVModbus.Server` の startup facade は、どちらも
`transport: :rtu | :ascii | :tcp` を必須とします。TCP Client は接続先を `host:` で指定します。
transport を暗黙に選ばないため、設定漏れは UART や listener を確保する前に
`{:error, :missing_transport_option}` となります。Server facade は option を transport-specific module に
委譲して standard `{:ok, pid}` を返します。transport-specific module は custom transport injection にも
利用できますが、戻り値の形式は facade と同じです。

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
- active binary socket の owner は protocol worker と分離した broker とし、slow handler 中も受信 message を処理
- worker へ未配送の broker binary は connection ごとの `max_buffer`（既定 2,048 bytes）で制限し、
  単一受信 chunk または蓄積 buffer の超過時は connection を閉じる
- active socket mailbox、worker が保持する現在の chunk / frame remainder、OS / runtime socket buffer は
  `max_buffer` に含めず、connection 全体の厳密な memory 上限とは扱わない
- broker は実行中の isolated handler も所有し、overflow、切断、eviction、server stop で worker とともに
  `:kill` で停止する。handler が `trap_exit` を有効にしても connection より長く残らない
- listener は handler 実行前の ownership handshake で fallback owner となり、broker が外部から
  `:kill` された場合も登録済み handler を停止する
- ownership transfer 中に届いた socket message も broker へ転送し、handoff failure 時は admitted broker も停止
- eviction / shutdown は全 broker で共有する 1 秒の graceful deadline と 100 ms の forced-stop deadline を持つ
- connection 上限では、最も多く connection を保持する address group の最古 connection を優先して evict
- address / network prefix allowlist、request 完了基準の idle timeout を提供
- invalid MBAP length では connection を閉じ、foreign protocol frame は破棄
- authorization、device identification、handler timeout は serial server と同じ core policy を使用
- pre-handoff shutdown / eviction、forced broker death、停止不能 broker、slow handler 中の receive overflow と
  反復 recovery、connection ごとの pipelined request、複数 managed client を組み合わせた load test で
  broker buffer 上限、wire order、lifecycle、connection 間の並行性と result correlation を検証

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

`AVModbus.UART` は AtomVM `:uart` を包み、連続受信と bounded buffering を提供する adapter です。

GPIO、baud rate、parity、board pinout、firmware install、polling loop は library の責務ではありません。これらは application または `examples/hello_atomvm_modbus` 側で設定します。

## 現在の制約

- 主対象は serial Modbus RTU / ASCII
- Modbus TCP は MBAP codec と managed client / server を実装済み
- RTU-over-TCP は未実装
- test 専用 duplex transport と TCP loopback を使う、任意実行の host soak test を提供済み
- XIAO ESP32-C5 / HW-519 間の実 RS485 baseline と workflow soak は完了済み
- 独立した software peer との相互運用性は pymodbus / libmodbus で検証済み。USB-RS485 adapter / commercial device は対象外
- retry は write の重複実行を避けるため、一般的な自動 retry としては提供していない
- Modbus/TCP Security は AtomVM に mutual-authenticated TLS client / server API がないため未実装
