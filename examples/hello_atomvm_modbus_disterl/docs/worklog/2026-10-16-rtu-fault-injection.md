# RTU fault injection — 2026-10-16

## 目的

実機で偶発的な error を待たずに、FC-100 transport が CRC error、連続 request timeout、response 消失を経ても
順序と at-most-once delivery を保って復旧することを確認する。

## 方法

host test で `Channel`、custom PDU、RTU frame、`Mailbox` を一続きにし、次の fault を順番に注入した。

1. CRC byte を反転した request frame を decode し、`:invalid_crc` になることを確認する
2. 8 回の request timeout を模擬し、Client が同じ session、sequence、payload の wire packet を保持することを確認する
3. 正常な request を Server に 1 回届けた後、response を 5 回連続で消失させる
4. Client の再送を Server に渡し、response frame が同一で、logical request の delivery count が 1 のままであることを確認する
5. 最後の response と ACK を通し、両方向の message 内容と両 Channel の完了を確認する

## 結果

28 host tests が成功した。CRC error と request timeout は Server state を変更せず、lost response 後の再送は同じ
logical request を重複 delivery しなかった。最後に Client は Server の queued message を受信し、Server は ACK を
受信して両方向とも完了した。

この test は RTU encode/decode と application transport の組み合わせを検証するが、実際の RS485 electrical noise、
UART driver の partial read、または timing を再現するものではない。それらは baud/poll matrix と長時間接続の実機項目に残す。
