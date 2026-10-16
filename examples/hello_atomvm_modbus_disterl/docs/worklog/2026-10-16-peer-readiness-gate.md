# FC-100 peer readiness gate実機検証 — 2026-10-16

## 目的

固定3秒startup delayを、Serverの実際の応答に基づくgateへ置き換えられるか確認する。Clientを3秒より十分長く先行させても、
Server起動前にAtomVM distribution setupを開始せず、Server起動後にgenuine distributionへ進むことを検証する。

## 構成

- `/dev/ttyACM0`: Server、XIAO ESP32-C5、USB serial `38:44:BE:A5:04:DC`
- `/dev/ttyACM1`: Client、XIAO ESP32-C5、USB serial `38:44:BE:A5:05:14`
- AtomVM `v0.7.0-beta.0+git.8d3e051`
- 9,600 baud、20 ms poll、96-byte chunk
- Client: `MODBUS_WAIT_FOR_PEER=1`、`MODBUS_START_DELAY_MS=0`
- payload 0 bytes、ping 3回

## 手順

1. 両boardへreadiness gateを含むfirmwareを書き込んだ
2. Serverをesptool bootloaderに保持した
3. Clientだけをresetし、Server不在のまま約70秒待機させた
4. Server applicationを起動した
5. Client consoleでreadiness、handshake、remote ping/pongを確認した

readiness中はpre-openしたModbusUARTがFC-100 empty pollを継続する。`net_kernel`はまだ開始しない。Server応答後もUARTを
reopenせず、同じadapter PIDを`serial_dist`へ渡した。

## 結果

```text
modbus_disterl: FC-100 peer ready; starting net_kernel
modbus_disterl: node :a@modbus.local
modbus_disterl: peer :b@modbus.local
modbus_disterl: virtual UART over FC 100 ready
modbus_disterl: received pong 1 from :b@modbus.local rtt_ms=4130 payload_bytes=0
modbus_disterl: first remote reply connection_ms=74401
modbus_disterl: received pong 2 from :b@modbus.local rtt_ms=1341 payload_bytes=0
modbus_disterl: received pong 3 from :b@modbus.local rtt_ms=1338 payload_bytes=0
modbus_disterl: complete 3 remote ping/pong messages rtt_min_ms=1338 rtt_avg_ms=2269 rtt_max_ms=4130 timeouts=0 elapsed_ms=81105
```

- Client先行時間は固定3秒delayの範囲を大きく超えた
- `net_kernel`開始はFC-100 peer readyの後だった
- genuine distribution handshakeとremote process messagingを完了した
- ping/pongは3 / 3、pong timeoutは0だった
- UART close / reopenに起因するerrorは観測しなかった

## 結論

Phase 2 Clientのdefault mitigationを固定3秒delayからFC-100 peer readiness gateへ変更する。これによりServer boot時間を
固定値で仮定せず、distribution setup timerをServer不在中に消費しない。

このrunはinitial setup前の起動順序問題を解決する証拠であり、readiness確認後に発生する任意のhalf-open handshakeや
runtime connection failureの一般的な回復保証ではない。AtomVM側pending cleanupの調査は継続する。
