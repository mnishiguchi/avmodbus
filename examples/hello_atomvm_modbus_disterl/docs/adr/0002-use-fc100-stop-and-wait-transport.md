# 0002: FC 100 上に stop-and-wait transport を構成する

## 背景

Modbus RTU は Client が request を開始し、Server が response を返す half-duplex の通信である。
両側が任意の時点で送信する byte stream を、そのまま RS485 上へ流すことはできない。

## 決定

- user-defined Function Code `100` (`0x64`) を transport frame に使用する
- Node A を Modbus Client、Node B を Modbus Server とし、Node A だけが物理 transaction を開始する
- 双方が独立した送信 queue を持ち、Node B の data は Node A の poll に対する response で返す
- 各方向で 1 chunk だけを in-flight とする stop-and-wait 方式を使用する
- 16-bit sequence number と acknowledgment で再送と重複抑止を行う
- 1 chunk の payload を最大 240 bytes とする

## 影響

Modbus の request-response 制約を保ったまま、論理的には双方向の順序付き配送ができる。
ただし throughput と latency は poll 間隔、Modbus timeout、1 transaction ごとの payload 上限に制約される。
また、現在の header には boot/session ID がないため、片側だけを再起動した場合の自動同期は保証しない。
