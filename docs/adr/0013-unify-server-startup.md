# 0013: Client / Server の transport startup を統一する

## 背景

transport ごとに異なる module や option 名を使うと、application の設定切り替えと supervision が複雑になる。
Client と Server で異なる既定 transport を選ぶと、設定漏れが意図しない UART / TCP 起動になる。

## 決定

- Client / Server とも `transport: :tcp | :rtu | :ascii` を必須とする
- TCP Client の接続先は `host:` で指定する
- `tcp: host`、`rtu: true`、`ascii: true` などの shorthand は提供しない
- transport 未指定は `{:error, :missing_transport_option}` とする
- Server facade は raw PID、Client facade は transport を識別できる tagged handle を返す
- transport-specific Server module は injection 用に維持するが、facade と同じ raw PID を返す

## 影響

application は Client / Server で同じ option 名を使って transport を切り替えられる。
起動設定は少し長くなるが、暗黙の transport 選択は発生しない。
