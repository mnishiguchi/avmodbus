# 0001: Modbus ライブラリとサンプル application を分離する

## 背景

Modbus 実装が複数 transport、Client / Server、各種 Function Code へ広がり、serial 通信のサンプルから
独立して保守する必要が生じた。

## 決定

- repository root を `avmodbus` library とする
- Mix application を `:avmodbus`、namespace を `AVModbus` とする
- runnable AtomVM application は `examples/hello_atomvm_modbus` に置く
- GPIO、firmware、polling など board 固有の設定は example 側で管理する

## 影響

protocol core を hardware から独立して再利用・テストできる。実機固有の手順は library API に持ち込まない。
