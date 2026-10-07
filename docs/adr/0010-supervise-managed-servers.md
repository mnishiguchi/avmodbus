# 0010: managed server の supervision contract を統一する

## 状態

採用

## 背景

RTU、ASCII、TCP server の `start_link` は transport を識別できる tagged handle を返す。
これは direct startup では便利だが、OTP supervisor の child start function が必要とする
`{:ok, pid}` とは一致しない。また transport ごとに lifecycle API の受け付ける形が異なると、
application supervision tree からの利用が複雑になる。

## 決定

- 各 managed server module は standard child specification を提供する
- child options の `:handler` を既存の `start_link(handler, options)` API に委譲する
- supervision 専用 start function は tagged handle から raw PID を返す
- `:name` option は local atom registration とする
- `status/1`、TCP の `port/1`、`close/1`、`stop/1` は tagged handle、raw PID、name を受け付ける
- direct `start_link` の result は後方互換のため tagged handle のまま維持する

## 理由

transport 固有 API と既存 application を維持しながら、どの server も通常の OTP supervision tree で
同じ方法で起動、参照、再起動できる。AtomVM 側にも supervisor 固有の abstraction を追加しない。
