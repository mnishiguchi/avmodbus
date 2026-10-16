# 0014: idle serial sync markerを未ACKの1 chunkへまとめる

## 背景

AtomVM `serial_dist`のlink managerは、接続相手を待つ間に2-byteのsync marker `AA 55`を500 msごとに
virtual UARTへwriteする。Modbus ServerはClientからrequestを受けるまでACKを得られないため、各markerを別chunkとして
queueすると、defaultの256-chunk上限へ約128秒で到達する。

これは有限queueが意図どおりbackpressureを返す動作だが、payloadを持たない同一のliveness markerによって、Clientの
起動可能時間が制限される。32-byteのdistribution preambleやapplication dataまでまとめるとbyte streamを変更するため、
対象を厳密に限定する必要がある。

## 判断

`DisterlProbe.ModbusUART`は、未ACKのexact 2-byte sync marker `AA 55`がoutgoingまたはpendingに存在する間、同じwriteを
成功として受け取り、新しいchunkを追加しない。

- 32-byte preamble、他の2-byte data、通常のdistribution frameはまとめない
- markerがACKされてqueueからなくなれば、次のmarkerは通常どおりqueueする
- 一般的な重複排除は行わず、FC-100 sequence / acknowledgmentの意味も変更しない

## 影響

Client不在中のServer queueは時間に比例して増えず、有限queueをapplication dataのbackpressureとして維持できる。
一方、この最適化はAtomVM `serial_dist`の現在のmarker値とidle動作に依存する。将来その仕様が変わる場合は、markerの識別と
coalescing条件を再確認する必要がある。

XIAO ESP32-C5実機ではServerを約210秒先行させた後にClientを起動し、genuine distribution handshakeとremote
ping/pong 3 / 3を完了した。詳細は
[Server先行時のidle sync coalescing実機検証](../worklog/2026-10-16-server-idle-sync-coalescing.md)に記録する。
