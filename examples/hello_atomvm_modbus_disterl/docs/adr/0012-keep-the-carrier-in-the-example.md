# 0012: experimental carrier を example 内に維持する

## 背景

この実験では、AVModbus の custom Function Code API だけを使って FC-100 reliable byte-stream transport を構成し、
AtomVM の `serial_dist` を変更せず genuine distributed Erlang を動作させられた。実装の中心である `Protocol`、
`Channel`、`Session`、`ModbusUART` は再利用できる形に見える一方、標準 Modbus の機能ではない独自 wire format、
queue と再送 policy、AtomVM distribution controller の lifecycle を一体として扱っている。

現時点の利用者はこの example だけであり、initial handshake の half-open connection、queue-full 時の stream reset、
shutdown 時の buffered data と blocked reader の扱いなど、公開 API として固定するには未解決の lifecycle contract が残る。

## 決定

- FC-100 carrier と `serial_dist` adapter は `examples/hello_atomvm_modbus_disterl/` 内に維持する
- proprietary reliable messaging を AVModbus core の一般 API へ移さない
- 現時点では独立 package に分離しない
- AVModbus core は Modbus protocol と custom Function Code の拡張点を提供する責務に留める
- example 外の具体的な利用者と安定した lifecycle / backpressure contract が得られた場合に、独立した companion package を再検討する

## 影響

AVModbus core の API と責務を広げずに、実験固有の変更と失敗条件を example 内で進化させられる。
一方、別 application から carrier を利用する場合は当面 module の直接再利用ではなく、必要な contract を整理してから
package 化を判断する。proof of concept が動作したこと自体は、core への昇格理由とはしない。

この判断は、実験開始時の分離方針を定めた [ADR 0001](0001-isolate-the-experiment.md) を、実機検証後の知見で
確定するものである。
