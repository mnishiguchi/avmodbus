# 0002: プロトコルコアとトランスポートを分離する

## 背景

Modbus の PDU と framing は、AtomVM の UART / socket lifecycle から独立している。

## 決定

- `AVModbus.PDU` は Function Code の encode / decode と validation だけを扱う
- RTU / CRC、ASCII / LRC、TCP / MBAP はそれぞれ専用 module に置く
- AtomVM `:uart` access は `AVModbus.UART` に閉じ込める
- connection lifecycle は codec から分離する
- protocol tests は通常の BEAM 上で実行可能にする
- Linux / Nerves 固有の runtime dependency は追加しない

## 影響

protocol correctness と hardware integration を別々に検証でき、transport を変更しても PDU core を共有できる。
