# 0007: Modbus TCP connection を独立 process で隔離する

## 背景

同じ connection の request order を保ちながら、複数 connection は互いに停止させず処理する必要がある。

## 決定

- listener が listen socket、admission、connection metadata を所有する
- accepted socket は connection process へ ownership transfer する
- connection process は wire order で request を処理し、connection 間は並行動作する
- 完全な request の受信だけを activity とし、partial byte で idle deadline を延長しない
- connection 上限では、最も多く保持する address group の最古 connection を evict する
- allowlist は address と IPv4 / IPv6 prefix を扱う
- invalid MBAP stream は connection を閉じる
- authorization と handler isolation は `AVModbus.Server` に委譲する

## 影響

遅い peer の影響を connection 内に閉じ込め、device の connection 数を制限できる。
