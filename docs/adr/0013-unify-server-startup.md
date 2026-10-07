# 0013: Server module を transport startup facade にする

## 状態

採用

## 背景

AVModbus は request processing と transport ownership を分離するため、RTU、ASCII、TCP ごとに
managed server module を提供してきた。この構造は adapter injection に有用だが、application の
supervision tree では transport ごとに module と startup result が異なり、設定切り替えが
煩雑だった。

## 決定

- `AVModbus.Server.start_link/1` を managed server の統一 startup facade とする
- transport 未指定時は TCP を選ぶ
- `transport: :tcp | :rtu | :ascii` を正規の明示指定とする
- compatibility shorthand として `tcp: true`、`rtu: true`、`ascii: true` も受け付ける
- 複数 transport 指定は `:multiple_transport_options` で拒否する
- facade の child specification / start result は standard raw PID とする
- `status/1`、`port/1`、`stop/1`、`close/1` は raw PID、name、transport tagged handle を扱う
- transport-specific module と tagged-handle API は injection と後方互換のため維持する

## 理由

application は一つの module を supervision tree に置いたまま transport を configuration で変更できる。
protocol processor と transport loop の責務分離、host test の injected transport、既存 application は
維持される。
