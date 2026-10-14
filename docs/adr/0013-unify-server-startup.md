# 0013: Client / Server の通信方式の指定方法を統一する

## 背景

通信方式ごとにモジュールやオプション名が違うと、アプリケーションの設定変更や Supervisor での管理が複雑になる。
Client と Server で異なる方式を既定にすると、指定漏れによって意図しない UART / TCP が起動するおそれもある。

## 決定

- Client / Server とも `transport: :tcp | :rtu | :ascii` を必須とする
- TCP Client の接続先は `host:` で指定する
- `tcp: host`、`rtu: true`、`ascii: true` などの省略記法は提供しない
- transport 未指定は `{:error, :missing_transport_option}` とする
- Server の共通 API は PID、Client の共通 API は通信方式を識別できるハンドルを返す
- 通信方式別の Server モジュールは差し替え用に残すが、共通 API と同じく PID を返す

## 影響

アプリケーションは Client / Server で共通のオプション名を使い、通信方式を切り替えられる。
起動時の指定は少し長くなるが、通信方式が意図せず選ばれることはない。
