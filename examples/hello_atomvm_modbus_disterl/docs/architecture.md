# アーキテクチャ

このサンプルは、Modbus RTU の request-response 制約の上に順序付きの双方向 byte stream を構成し、
AtomVM の既存 `serial_dist` へ virtual UART として提供します。採用理由は
[設計判断記録](adr/README.md) に記録します。

## Phase 1: logical transport

```text
Node A: Modbus Client                    Node B: Modbus Server (Unit 1)

logical TX queue                              logical TX queue
       |                                             |
       +------ request: FC 100 + seq/ack/data ------>+
       +<---- response: FC 100 + seq/ack/data -------+

Only Node A initiates physical RTU transactions.
Node B sends queued data only in a response to a poll.
```

独自 payload は次の形式です。整数は big-endian です。

```text
<<version:8, session:32, sequence:16,
  acknowledged_session:32, acknowledgment:16, payload::binary>>
```

- wire protocol の payload は 1 chunk 最大 232 bytes（header と合わせて version 1 と同じ 245 bytes）
- virtual UART の default operating chunk は 96 bytes で、FC-100 header、PDU、RTU framing を含む request / response を
  114 bytes に抑える。`MODBUS_CHUNK_PAYLOAD_BYTES` で 1..232 の範囲を指定できる
- 各方向で 1 chunk を in-flight にし、それ以降は FIFO に保持する
- ACK されるまで同じ sequence と payload を再送する
- 受信済み sequence の再送は配達せず、ACK だけを再送する
- `sequence = 0` は送信 data なし、`acknowledgment = 0` は ACK なしを表す
- data sequence は `1..65,535` を使い、65,535 の次は 1 へ wrap する
- ACK の新旧は wraparound を考慮した serial-number arithmetic で判定する
- 未 ACK message が sequence 空間全体を占有した場合は、新しい message の queue を拒否する
- 各起動時に non-zero の 32-bit session ID を生成する
- ACK は `acknowledged_session` と一致する local session にだけ適用する
- peer session が未確定のとき、以前の local session 宛ての packet は payload を含めて破棄する
- 新しい peer session の最初の packet は、reset 済み sequence state に対する ACK validation を行わない
- 新しい peer session を受信した側は、その最初の sequence を新しい receive baseline として受け入れる
- 既知の peer が session を変更した場合は、その peer 向けに queue した古い byte-stream data を破棄する

## Phase 2: distributed Erlang

`DisterlProbe.ModbusUART` を `serial_dist` の `uart_module` として指定します。この adapter が
`open/read/write/close` の byte-stream API と FC-100 chunk を相互変換します。

`serial_dist` 自身の framing、CRC32、distribution handshake、distribution controller を再利用するため、
remote ping/pong は application 独自の protocol ではなく genuine Erlang distribution 上を通ります。
`DISTERL_PAYLOAD_BYTES` を設定すると deterministic binary を ping に含め、Server が内容を検証して echo し、
Client が同じ binary を再検証します。

Client は handshake 中に 500 ms の response timeout を使います。`serial_dist` が operating chunk を超える write を
queue した後は 2000 ms の bulk timeout に切り替え、peer session が変わると 500 ms に戻します。これにより
AtomVM の 7 秒 handshake budget を維持しながら、接続後の multi-chunk traffic に余裕を与えます。

`MODBUS_TRACE_TRANSACTIONS=1` では Client の non-idle physical transaction と全 failure について request /
response byte 数、経過時間、poll 番号、最大 latency、累積 success / failure 数を出力します。13-byte の
empty poll 成功は timing への影響を抑えるため出力せず、counter にだけ含めます。通常実行では最初の
3 failure だけを表示します。

```text
net_kernel / dist_util / distribution controller
                       |
                    serial_dist
                       |
             DisterlProbe.ModbusUART
                       |
       FC-100 stop-and-wait logical transport
                       |
                AVModbus RTU / UART1
```

virtual UART adapter は `read(handle)` に加え、handshake receive が使用する
`read(handle, :infinity)` を実装します。handshake timeout 後に controller が終了して blocked reader が
残った場合は、次の接続試行が stale reader を置き換えます。

接続済み peer の session 変更を検出した場合、adapter は古い controller の infinite read に
`{:error, :closed}` を返します。`serial_dist` link manager は idle state に戻り、transport に buffer した
新しい peer の handshake data を使って接続を作り直します。有限 timeout の read は handshake または
idle scan に使われるため中断しません。
