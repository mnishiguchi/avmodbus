# 0007: Modbus TCP connection を独立 process で隔離する

## 状態

採用

## 背景

Modbus TCP は同じ connection の request を順番に処理する一方、複数 client connection は並行して扱う。
AtomVM 0.7 の `:gen_tcp` は active socket と `controlling_process/2` を提供するが、OTP の
`:inet.setopts/2` を前提とした active-once loop は利用できない。

## 決定

- listener process が listening socket、admission、connection metadata を所有する
- acceptor は accepted socket を connection process に transfer し、transfer 前に届いた message も転送する
- connection process は active binary socket を所有し、request を wire order で処理する
- 異なる connection process は独立して handler を実行する
- 完全な Modbus request の受信だけを activity として同期記録し、partial byte は idle deadline を延長しない
- connection 上限では address ごとの保持数を考慮し、最も多く保持する group の最古 connection を evict する
- allowlist は exact address と IPv4 / IPv6 network prefix を扱う
- invalid MBAP length は stream boundary を回復できないため connection を閉じる
- authorization、device identification、handler isolation は `AVModbus.Server` core に委譲する

## 理由

遅い client や handler が他の connection を止めず、limited-resource device で connection 数を明示的に制限できる。
active socket ownership を明確にすることで、AtomVM と OTP の共通 implementation を維持できる。
