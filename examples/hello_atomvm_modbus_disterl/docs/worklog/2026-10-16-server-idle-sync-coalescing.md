# Server先行時のidle sync coalescing実機検証 — 2026-10-16

## 目的

Client不在中にAtomVM `serial_dist`が繰り返す2-byte sync markerを1個の未ACK chunkへまとめ、Serverのoutgoing queueが
時間だけで256-chunk上限へ到達しないことを確認する。従来なら上限へ達する約128秒を越えてServerを単独待機させた後、
genuine distributionへ進めるか実機で検証する。

## 構成

- `/dev/ttyACM0`: Server、XIAO ESP32-C5、USB serial `38:44:BE:A5:04:DC`
- `/dev/ttyACM1`: Client、XIAO ESP32-C5、USB serial `38:44:BE:A5:05:14`
- AtomVM `v0.7.0-beta.0+git.8d3e051`
- 9,600 baud、20 ms poll、96-byte chunk
- outgoing queue上限: 8 KiB / 256 chunks
- payload 0 bytes、ping 3回

## 原因と変更

`serial_dist`のidle link loopはread timeoutの500 msごとに`AA 55`をvirtual UARTへwriteする。Modbus ServerはClientから
requestを受けるまで送信もACK受信もできないため、変更前は約128秒で256個の未ACK chunkがqueueを占有し得た。

adapterは、exact 2-byte marker `AA 55`がoutgoingまたはpendingに残っていれば同じwriteを追加しない。32-byteの
distribution preamble、他の2-byte data、通常frameは対象外とした。host testではmarkerがoutgoingの場合と、別dataの後ろで
pendingの場合を分けて確認した。

## 手順

1. coalescingを含むServer firmwareを書き込んだ
2. Clientをesptool bootloaderに保持した
3. Serverをresetし、Client不在のまま約210秒待機させた
4. Client applicationを起動した
5. 両consoleでhandshakeとremote ping/pongを確認した

## 結果

待機中にqueue rejectionやprocess終了は観測しなかった。Client起動後はFC-100 peer readinessを直ちに確認し、同じ
virtual UARTでgenuine distribution handshakeへ進んだ。

```text
modbus_disterl: FC-100 peer ready; starting net_kernel
modbus_disterl: sending ping 1 to :b@modbus.local payload_bytes=0
modbus_disterl: received pong 1 from :b@modbus.local rtt_ms=3535 payload_bytes=0
modbus_disterl: first remote reply connection_ms=6016
modbus_disterl: received pong 2 from :b@modbus.local rtt_ms=1337 payload_bytes=0
modbus_disterl: received pong 3 from :b@modbus.local rtt_ms=1339 payload_bytes=0
modbus_disterl: complete 3 remote ping/pong messages rtt_min_ms=1337 rtt_avg_ms=2070 rtt_max_ms=3535 timeouts=0 elapsed_ms=12718
```

- Server先行時間は従来の256-chunk到達見込み時間を約82秒超えた
- genuine distribution handshakeを完了した
- remote ping/pongは3 / 3、pong timeoutは0だった
- Server側でもping 1–3の受信を確認した

その後Clientも同じ最終sourceから再build / flashし、ready済みServerに対するregressionを行った。最初のFC-100 poll
timeout 1回から自動復旧し、ping/pong 3 / 3、pong timeout 0、first remote reply 6,032 msで完了した。

## 結論

exact idle sync markerのcoalescingにより、Client不在時間だけを理由にServerの有限queueを使い切る問題を解消した。
通常dataは従来どおり8 KiB / 256 chunksの上限を受けるため、bounded queueとfail-fastの方針は維持される。

このrunは2-nodeのServer-first startupを1回確認した結果であり、任意の通信断、長時間運転、AtomVM側のhalf-open
connection recoveryを一般に保証するものではない。
