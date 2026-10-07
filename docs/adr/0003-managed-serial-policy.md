# 0003: serial client / server は managed process で共通 policy を使う

## 状態

採用

## 背景

Modbus serial line では同じ bus 上で transaction を競合させず、frame timing、timeout、broadcast、echo、disconnect recovery を一貫して扱う必要がある。

RTU と ASCII で framing は異なるが、transaction ownership と lifecycle policy の多くは共通である。

## 決定

### クライアント

- managed client process が UART を所有し、request を直列化する
- sync / async request は同じ deadline model を使う
- queue 待ち時間も timeout に含める
- RTU は送信前に frame gap を確保する
- broadcast write は response を読まず turnaround delay を待つ
- optional adapter echo suppression を提供する
- owned UART failure 後は bounded exponential backoff で reopen する

### サーバー

- serial server process が UART と line-level state を所有する
- unit filtering、broadcast、diagnostics、event counters、listen-only state を transport 側で扱う
- owned UART failure 後は state を保持したまま reopen する
- RTU / ASCII は request dispatch、handler policy、reconnect policy を共有する

## 理由

serial bus の ownership と recovery responsibility を一箇所に集め、RTU / ASCII 間の behavior drift を避けるため。
