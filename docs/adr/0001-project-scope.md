# 0001: Modbus ライブラリとサンプル application を分離する

## 状態

採用

## 背景

当初は `hello_atomvm_serial` で serial distributed Erlang と RS485 / Modbus RTU を一緒に試していた。

Modbus 実装が client / server、複数 function、RTU / ASCII へ広がり、単なる serial sample ではなく独立した library として保守する必要が出てきた。

## 決定

- `hello_atomvm_serial` は serial distributed Erlang の sample として維持する
- repository root を `avmodbus` library とする
- Mix application は `:avmodbus`、Elixir namespace は `AVModbus` とする
- runnable AtomVM application は `examples/hello_atomvm_modbus` に置く
- GPIO、firmware tooling、polling 設定などは example 側で管理する

## 理由

library と board-specific application の責務を分離し、protocol core を再利用・テスト・将来 Hex package 化しやすくするため。
