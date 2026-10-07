# 0018: managed client の既定 request timeout を startup option にする

## 状態

採用

## 背景

request helper の timeout 省略時は常に 1,000 ms を渡していた。このため device や network の
応答特性に合わせて client 全体の deadline を変更するには、すべての call site に同じ timeout を
繰り返し指定する必要があった。

## 決定

- serial / TCP managed client の startup に正の millisecond 値を取る `:timeout` option を追加する
- default は 1,000 ms とする
- request timeout の省略時だけ startup default を使う
- positional timeout または request keyword の `timeout:` は startup default を上書きする
- deadline は API submission 時刻から計算し、serial mailbox または TCP wait queue の待ち時間を含める
- unmanaged UART transaction の timeout 省略時は従来どおり 1,000 ms を使う

## 理由

client 単位の default は、同じ bus / endpoint に共通する応答時間 policy を一箇所で設定できる。
request 単位の override を残すことで、遅い diagnostics や短い polling deadline も表現できる。
submission 時刻を managed process に渡すことで、client process が request を処理するまでの待ち時間を
deadline から除外しない。

## 影響

timeout を省略した既存 application の behavior は 1,000 ms のまま変わらない。startup `timeout:` は
0 を許可せず `{:error, :invalid_timeout_option}` を返す。一方、request 単位では即時確認用途の
0 ms timeout を引き続き許可する。serial では non-broadcast request かつ transmit gap が 0 の場合だけ
一度の即時 attempt を行い、待機はしない。
