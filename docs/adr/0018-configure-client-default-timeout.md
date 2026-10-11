# 0018: managed Client の既定 timeout を起動時に設定する

## 背景

すべての call site で同じ timeout を指定せず、接続先ごとの応答時間方針を一箇所に置きたい。

## 決定

- serial / TCP Client の `:timeout` option を既定 request deadline とする
- 既定値は 1,000 ms とし、起動時は正の値だけを許可する
- request 単位の positional / keyword timeout は起動時設定を上書きする
- deadline は API submission から数え、serial mailbox / TCP queue の待ち時間を含める
- unmanaged UART API は従来の 1,000 ms を維持する
- request 単位の 0 ms timeout は即時確認用として維持する

## 影響

既存 behavior を変えず、Client 単位と request 単位の両方で deadline を設定できる。
