# 0004: server application の境界を transport から分離する

## 状態

採用

## 背景

UART framing と application data model を同じ process に実装すると、protocol validation、device logic、recovery policy が密結合になる。

## 決定

- `AVModbus.Server` は transport-independent な request processor とする
- application handler は function または `{module, argument}` で注入する
- handler は monitored process で実行し、timeout / crash を Modbus exception に変換する
- authorization と device identification を server policy として扱う
- `AVModbus.Memory` は optional な sparse in-memory handler とする
- serial diagnostics は application handler ではなく serial server が所有する

## 理由

application 固有ロジックを UART lifecycle から分離し、hardware なしで server semantics をテストできるようにするため。
