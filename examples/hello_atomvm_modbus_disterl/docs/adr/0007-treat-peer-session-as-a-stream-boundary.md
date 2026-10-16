# 0007: peer session の観測を stream synchronization boundary とする

## 背景

両 node をほぼ同時に reset すると、UART または RTU receive buffer に残った直前の boot session の response を、
新しい endpoint が最初に受信する場合があった。peer session が未確定の state はその古い session を一度採用し、
続いて現在の session を受信すると transport state を reset した。

reset と同じ packet の ACK を初期化済み sequence に対して検証すると `invalid_acknowledgment` が継続した。また、
以前の local session 宛ての payload を新しい `serial_dist` reader に配達すると handshake stream が壊れ、
`illegal_data_value` と distribution setup timeout になった。

これは [0004](0004-resynchronize-with-session-ids.md) の session-aware resynchronization を補足する判断である。

## 決定

- peer session が未確定で、packet の `acknowledged_session` が `0` でも現在の local session でもない場合、packet
  全体を以前の boot session の残留 data とみなし、peer session を採用せず payload も配達しない
- 既知の peer session が変わった最初の packet では、破棄した旧 outgoing queue に対する ACK validation を行わない
- session 変更時は従来どおり outgoing / pending data と sequence state を reset する
- 新しい session boundary の後は、future ACK と out-of-order sequence を従来どおり拒否する

## 影響

以前の local session 宛ての in-flight data は再利用せず、新しい distribution stream で再送する。これにより stale
payload が新しい handshake に混入せず、両 node の近接した reboot でも transport が現在の session pair へ収束する。

最初の packet だけ ACK validation を緩和するが、reset 後の outgoing queue は空であるため message を誤って ACK 済みに
することはない。通常の同一 session 内では ACK と順序の検証を維持する。
