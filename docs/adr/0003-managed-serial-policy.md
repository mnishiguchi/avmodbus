# 0003: serial Client / Server は managed process で方針を共有する

## 背景

1 本の serial bus では transaction、frame timing、timeout、broadcast、切断復旧を一貫して管理する必要がある。

## 決定

- managed process が UART を所有し、request を直列化する
- queue 待ち時間を deadline に含める
- RTU の frame gap、broadcast turnaround、optional echo suppression を transport で扱う
- UART failure 後は bounded exponential backoff で reopen する
- Server は unit filtering、broadcast、diagnostics、listen-only state を所有する
- RTU / ASCII で request dispatch、handler、reconnect の方針を共有する

## 影響

UART ownership と復旧責任が明確になり、RTU / ASCII 間の挙動差を抑えられる。
