# 0011: queue-full を transport session boundary とする

## 背景

8 KiB outgoing limit を超えた write は atomic に拒否され、local `serial_dist_controller` は
`{serial_write_error, queue_full}` で終了した。しかし FC-100 Channel の session が変わらないまま polling を続けると、
peer の controller は確立済み data phase に残る。次の handshake bytes と以前の stream state が混在し、実機では
`crc_error` となって再接続できなかった。

queue-full 後は拒否した write だけでなく、その byte stream connection 全体を継続できない。peer にも同じ境界を
通知する必要がある。

## 決定

- `ModbusUART.write/2` が `:queue_full` を返すとき、Channel queue と receive buffer を破棄し、新しい local session IDへ
  rolloverする
- response timeoutを初期値へ戻し、以後のempty pollで新しいsession IDをpeerへ通知する
- peerは既存のsession-change処理で古いinfinite readerへ`{:error, :closed}`を返し、peer controllerも終了させる
- byte / chunk limitと`serial_write_error`によるlocal controllerのfail-fastは維持する
- `:queue_full`以外のqueue errorではsessionを変更しない

## 影響

queue-full は単一 write の失敗ではなく、buffered / in-flight dataをすべて破棄する明示的なstream boundaryになる。
deliveryはdurableでもexactly-onceでもなく、applicationは新しいdistribution connectionでmessageを再送する必要がある。

8 KiB queue-full probeの実機runでは、Serverがsession changeを検出して旧readerを閉じ、15秒後のapplication retryで
handshakeとzero-byte ping/pongを完了した。初回oversize pingに対応するpong timeoutは1回、復旧後のRTTは3,696 msだった。

これは確立済みconnectionのlocal queue-full recoveryに限る。initial handshake中に生じるAtomVM `net_kernel`の
pending connection cleanup問題を一般に解決するものではない。
