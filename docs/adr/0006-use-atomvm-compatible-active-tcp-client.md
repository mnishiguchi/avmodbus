# 0006: managed TCP client は AtomVM-compatible active socket を所有する

## 状態

採用

## 背景

Modbus TCP は transaction id により複数 request を同じ connection 上で並行処理できる。
一方、AtomVM 0.7 の `:gen_tcp` は active / passive socket と `controlling_process/2` を提供するが、
OTP の connect timeout 引数や socket option の全ては提供しない。

## 決定

- managed TCP client process が active binary socket と receive buffer を所有する
- blocking connect は connector process に隔離し、client process の timer で timeout を管理する
- AtomVM と OTP の両方にある `connect/3`、`controlling_process/2`、`send/2`、`close/1` だけを使う
- request deadline は connection 待ち、queue 待ち、response 待ちを全て含む
- `:max_pending` まで送信し、transaction id で out-of-order response を照合する
- response の unit id は既定で検証し、互換性が必要な gateway 向けに `check_unit: false` を許可する
- invalid MBAP length は stream boundary を回復できないため connection を閉じる
- response が一切ない request timeout が二回続いた connection は half-open と判断する
- socket failure 後は bounded exponential backoff で reconnect する

## 理由

AtomVM 固有 adapter を増やさず、同じ lifecycle behavior を host tests と device runtime で使える。
また transaction concurrency を framing codec から分離し、将来の TCP server 実装と PDU core を共有できる。
