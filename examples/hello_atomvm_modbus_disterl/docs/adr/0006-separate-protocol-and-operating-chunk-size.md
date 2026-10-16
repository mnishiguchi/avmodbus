# 0006: protocol 上限と operating chunk size を分離する

## 背景

FC-100 transport format は 232-byte payload を表現できるが、XIAO ESP32-C5 と HW-519 を 9,600 baud で使った
実機試験では、上限付近の request / response が timeout と再送を繰り返した。500 ms から 1,000 ms、2,000 ms へ
deadline を延ばしても安定せず、128-byte payload（RTU frame 145 bytes）も Server に届かなかった。一方、handshake
で成功した frame と 96-byte payload（RTU frame 113 bytes）は安定して処理できた。

## 決定

- wire protocol の payload 上限 232 bytes は変更しない
- virtual UART の default operating chunk を 96 bytes とする
- `MODBUS_CHUNK_PAYLOAD_BYTES` で 1..232 bytes を明示的に変更できるようにする
- handshake 中は 500 ms の transaction timeout を維持する
- operating chunk より大きい `serial_dist` write を queue した後だけ 2,000 ms の bulk timeout を使う
- peer session が変わったら handshake timeout に戻す

## 影響

default の FC-100 request / response は transport header、custom PDU、RTU framing を含めて最大 113 bytes になる。
transaction 数と latency は増えるが、512-byte genuine distribution ping/pong は 2 台の実機で双方向に完了した。
232-byte payload は interoperability 上の capacity として残るものの、この hardware 構成で信頼できる operating value
とはみなさない。bulk timeout は handshake failure の retry budget を消費せず、接続後の traffic にだけ適用される。
