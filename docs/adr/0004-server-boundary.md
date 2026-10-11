# 0004: Server application の境界を transport から分離する

## 背景

framing、UART lifecycle、application data model を同じ process に置くと、通信処理と機器ロジックが密結合になる。

## 決定

- `AVModbus.Server` を transport-independent な request processor とする
- handler は function または `{module, argument}` で注入する
- handler の timeout / crash は Modbus exception に変換する
- authorization と device identification は Server policy として扱う
- `AVModbus.Memory` は optional な sparse in-memory handler とする
- serial diagnostics は serial Server が所有する

## 影響

application 固有ロジックを transport lifecycle から分離し、hardware なしで Server semantics をテストできる。
