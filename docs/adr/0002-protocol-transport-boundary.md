# 0002: プロトコルコアとトランスポートを分離する

## 状態

採用

## 背景

AtomVM では ESP32 の `:uart` や socket API を使う。一方、Modbus の PDU、RTU / ASCII framing、MBAP framing は transport implementation と独立している。

protocol behavior の正は Modbus Organization の仕様書とする。

## 決定

- `AVModbus.PDU` を transport-independent にする
- RTU framing / CRC は `AVModbus.RTU` / `AVModbus.CRC16` に置く
- ASCII framing / LRC は `AVModbus.ASCII` に置く
- Modbus TCP の MBAP framing は `AVModbus.TCP` に置く
- AtomVM `:uart` access は `AVModbus.UART` に閉じ込める
- TCP connection lifecycle は MBAP codec から分離する
- protocol tests は通常の BEAM 上で実行できるようにする
- Linux / Nerves 固有の runtime dependency は追加しない

## 理由

protocol correctness と hardware integration を独立して検証でき、AtomVM の API / memory 制約に合わせた transport を維持できるため。
