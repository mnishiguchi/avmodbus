# 0016: serial asynchronous result は deadline arbiter で一度だけ通知する

## 状態

採用

## 背景

managed serial client は UART ownership と transaction serialization のため、1 request の read 中は
次の mailbox message を処理しない。queue 待ち時間も timeout に含めていたが、短い deadline の
asynchronous request が active transaction の後ろに並ぶと、timeout result の通知自体が deadline より
遅れる可能性があった。

UART transaction を別 process に移すと AtomVM UART ownership と serial bus serialization が複雑になる。
一方、caller と transaction result の間で deadline を arbitration すれば、UART owner は変更せずに
late result と timeout の競合を一箇所で解決できる。

## 決定

- 正の timeout を持つ serial asynchronous request ごとに軽量な deadline arbiter process を起動する
- managed serial client は transaction result を arbiter に送り、arbiter は result または deadline
  timeout のうち先に確定した一方だけを recipient に転送する
- deadline 後に届いた transaction result は arbiter process の終了によって破棄する
- zero-timeout request は従来どおり、すぐ利用可能な response を許す経路を維持する
- UART open / read / write、serialization、reconnect ownership は managed client process に残す
- TCP client は event loop 内の per-request timer と pending / queue removal を引き続き使う

## 理由

public result reference ごとに deadline-bounded exactly-once delivery を保証しながら、AtomVM 上で重要な
UART ownership model と既存の transaction implementation を変更しない。arbiter は request 完了または
deadline で終了するため、lifetime は有界である。
