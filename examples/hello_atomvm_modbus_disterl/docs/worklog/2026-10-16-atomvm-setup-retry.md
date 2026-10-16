# AtomVM setup PID cleanupとhandshake retry実機A/B — 2026-10-16

## 目的

FC-100 peer readiness確認後にdistribution setupが終了した場合、application retryが新しいsetupを開始できない問題を
AtomVM `net_kernel`側で修正する。local pending entryだけでなくpeer側のhalf-open controllerを含め、実機で最終的に
genuine distribution handshakeへ戻れるか確認する。

## AtomVM修正

AtomVM `release-0.7`の`4ef13692`からbranch `fix/net-kernel-setup-pid`を作成した。最初のoutgoing connectで
`ProtoDist:setup/5`の返すPIDを破棄せず、connection mapへ次のように保存する。

```erlang
ConnPid = ProtoDist:setup(OtherNode, normal, MyNode, Longnames, ?SETUPTIME),
maps:put(OtherNode, {pending, ConnPid, DHandle}, Connections)
```

setup processが`dist_util:mark_pending/4`より前に終了しても、既存の`'EXIT'` handlerがPIDを一致させてentryを削除できる。
後続connectはstale pending entryの`DHandle`だけを更新せず、新しい`ProtoDist:setup/5`を呼ぶ。

修正commitは`735841ba` (`Fix retry after early distribution setup exit`) である。AVModbus exampleへAtomVM moduleを複製せず、
upstream用の独立branchに置いた。

## AtomVM回帰test

socket、EPMD、cryptoを使わない`test_net_kernel_pending`とmock distribution moduleを追加した。testは
`net_kernel:handle_info/2`へconnectを渡し、返されたsetup PIDがpending entryへ保存されること、そのPIDのearly EXIT後にentryが
削除され、次のconnectが別PIDのsetupを開始することを確認する。

同じtestを旧実装と修正後で実行した。

| 実装 | 結果 |
| --- | --- |
| 旧 `{pending, undefined, DHandle}` | exit 1、`{badmatch,{pending,undefined,...}}` |
| setup PID保存patch | exit 0、`Return value: ok` |

追加で次を確認した。

- `erlfmt 1.7.0` check成功
- 変更Erlang moduleの`erlc -Werror`成功
- Generic UNIX AtomVM build成功
- `test_estdlib` target build成功
- `elixir_esp32boot.avm` build成功、509,584 bytes / 512 KiB partition

Generic UNIXのfull `test_estdlib`実行はsandboxのsocket `eperm`と、local buildにMbedTLSがなく
`crypto:strong_rand_bytes/1`が使えないためnetwork suiteが失敗した。これらを修正結果には数えず、対象testを独立AVMとして
旧実装と修正後の両方で実行した。

## 実機構成

- `/dev/ttyACM0`: Server、XIAO ESP32-C5、USB serial `38:44:BE:A5:04:DC`
- `/dev/ttyACM1`: Client、XIAO ESP32-C5、USB serial `38:44:BE:A5:05:14`
- runtime binary: AtomVM `v0.7.0-beta.0+git.8d3e051`
- boot library: AtomVM `release-0.7` `4ef13692` + `735841ba`
- 9,600 baud、20 ms poll、96-byte chunk
- Client: FC-100 readiness gate有効、ping payload 0 bytes、ping 3回
- Server fault: `MODBUS_FAULT_DROP_RESPONSES=40`、`MODBUS_FAULT_MIN_PAYLOAD_BYTES=32`、
  `MODBUS_FAULT_AFTER_MS=0`

両boardの元の512 KiB boot partitionを保存してから、修正版`elixir_esp32boot.avm`だけを`0x1d0000`へ書き込んだ。
main applicationとruntime binaryは別partitionのままである。

## positive run

2-byte readiness markerはfault対象外とし、Clientが`net_kernel`を開始した後の最初の32-byte distribution preamble responseを
40回Modbus exceptionへ置換した。初回setupは7秒timerで終了し、stale handshake dataによる追加failureも発生した。

```text
modbus_disterl: sending ping 1 to :b@modbus.local payload_bytes=0
modbus_uart: queued bytes=32
modbus_uart: queued bytes=37
dist_util: shutting down connection dist_util:188, data=timer_timeout, reason=shutdown
dist_util: shutting down connection dist_util:225, data={unexpected,<<"sok">>}, reason=shutdown
dist_util: shutting down connection dist_util:402, data={unsupported_name,<<>>}, reason=shutdown
modbus_disterl: pong 1 timed out; retrying
modbus_disterl: sending ping 1 to :b@modbus.local payload_bytes=0
modbus_uart: queued bytes=32
modbus_uart: queued bytes=37
modbus_disterl: received pong 1 from :b@modbus.local rtt_ms=3823 payload_bytes=0
modbus_disterl: first remote reply connection_ms=23331
modbus_disterl: complete 3 remote ping/pong messages rtt_min_ms=1331 rtt_avg_ms=2163 rtt_max_ms=3823 timeouts=1 elapsed_ms=30026
```

Server側でも最初のcontrollerが`timer_timeout`で終了し、次の32 / 37-byte handshake、ping 1–3を受信した。peer側の
half-open stateは既存setup timerで終了し、local pending cleanup後の再接続と合流できた。

## 旧boot libraryとのnegative control

Clientだけを保存済みの旧boot libraryへ戻し、Serverをresetして同じ40-response faultを再実行した。初回setupは同じく
`timer_timeout`になったが、その後のapplication ping retryでは新しい32-byte writeが一度も発生しなかった。

```text
dist_util: shutting down connection dist_util:188, data=timer_timeout, reason=shutdown
modbus_disterl: pong 1 timed out; retrying
modbus_disterl: sending ping 1 to :b@modbus.local payload_bytes=0
modbus_disterl: pong 1 timed out; retrying
modbus_disterl: sending ping 1 to :b@modbus.local payload_bytes=0
modbus_disterl: pong 1 timed out; retrying
modbus_disterl: sending ping 1 to :b@modbus.local payload_bytes=0
```

Server側もfault budget消費後のsetup timeout以降は新しいtrafficを受信しなかった。source調査で予測した
`{pending, undefined, DHandle}`のstale entryと一致する。

## 最終regressionと結論

negative control後はClientを修正版boot libraryへ戻し、Server main applicationをfaultなしのdefaultへ戻した。両boardが
修正版boot libraryの状態でping/pong 3 / 3、pong timeout 0を完了した。RTT min / average / maxは
1,330 / 2,213 / 3,743 ms、first remote replyは6,213 msだった。

setup PID保存は、今回のreadiness後failureでlocal stale pending entryを除去し、application retryを実際のnew setupへ変える。
実機A/Bでも旧版の停止と修正版の復旧を分離できた。ただしpeer cleanupは今回のsetup timer条件で確認しただけで、任意の
controller failureや長時間通信断に対する一般保証ではない。公式AtomVM releaseへ取り込まれるまでは、この結果をexampleの
default runtime保証とはしない。
