# 0013: `AVModbus.Server` を transport startup facade にする

## 背景

transport ごとに異なる module を直接起動すると、application の設定切り替えと supervision が複雑になる。

## 決定

- `AVModbus.Server.start_link/1` を統一 entrypoint とする
- `transport: :tcp | :rtu | :ascii` で選択し、省略時は TCP とする
- compatibility 用の boolean shorthand も維持する
- 複数 transport の指定は拒否する
- facade は raw PID を返す
- transport-specific module と tagged handle は injection と後方互換のため維持する

## 影響

application は module を変えずに transport を設定で切り替えられる。
