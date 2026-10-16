# Modbus transaction tracing — 2026-10-16

## 目的

multi-chunk distribution payload の timeout を、application log からの推測ではなく physical Modbus
transaction 単位の size と latency で調査できるようにする。

## 実装

`MODBUS_TRACE_TRANSACTIONS=1` または `true` で、Client の non-idle poll と全 failure に次の値を出力する。

- poll number
- outcome (`ok` / `error`)
- custom-function request / response payload bytes
- elapsed milliseconds
- error reason
- cumulative successes / failures
- observed maximum latency

```text
modbus_uart: transaction poll=42 outcome=ok request_bytes=13 response_bytes=245 elapsed_ms=...
modbus_uart: transaction poll=43 outcome=error request_bytes=13 elapsed_ms=500 reason=:timeout ...
```

tracing を無効にした通常実行では、従来どおり最初の 3 poll failure だけを表示する。計測 state と event の
生成は pure `TransactionStats` module に分離し、success / failure aggregation、byte count、elapsed time、
maximum latency を host test で確認した。

13-byte request / 13-byte response の empty poll 成功は counter に含めるが log には出さない。20 ms poll
interval で UART0 log 自体が測定対象の timing を変えることを避けるためである。

## 次の実機試験

board と HW-519 を power-cycle した後、zero-byte baseline と 512-byte payload を tracing 有効で再実行する。
特に `request_bytes=13` / `response_bytes=245` の transaction latency と timeout 率を比較し、handshake 用の
短い deadline と bulk response 用 deadline を分離できる根拠を集める。
