# 0015: Modbus/TCP Security は必要な AtomVM TLS capability まで fail closed する

## 状態

採用

## 背景

Modbus/TCP Security は TLS 1.2 以降、client / server 双方の certificate、peer verification、
client certificate の role による authorization を必要とする。対応を名乗るには暗号化だけでなく
mutual authentication が必要である。

pinned AtomVM 0.7 の `:ssl` module は `connect/3`、`send/2`、`recv/2`、`close/1` を中心とする
client API だけを公開する。server の listen / accept / handshake API はなく、client option の
verification は `verify_none` だけで、certificate / key / CA trust configuration も公開されない。

## 決定

- `AVModbus.Client.start_link/1` の `tls:` / `ssl:` request は
  `{:error, :tls_not_supported}` を返す
- `AVModbus.Server.start_link/1` の `transport: :tls` / `tls:` / `ssl:` request も同じ error を返す
- transport-specific TCP server に `tls:` / `ssl:` を渡した場合も同じ error を返す
- `verify_none` の client-only TLS を Modbus/TCP Security として提供しない
- TLS capability の不足を generic unknown-option error に隠さない

## Enablement criteria

次を AtomVM 上で満たせる場合にこの判断を見直す。

- TLS 1.2 以降に制限できる client / server transport
- server listener、accept、bounded handshake timeout
- client と server 双方の certificate / private key configuration
- CA trust と peer certificate verification
- client certificate を必須にできる server policy
- authorization に渡す peer identity または role を安全に取得する API
- connection lifecycle、timeout、hostile peer を通常の TCP path と同等に隔離できること

## 理由

暗号化されていても peer を検証しない接続は Modbus/TCP Security の trust model を満たさない。
unsupported feature を明示して fail closed する方が、caller が安全な transport と誤認することを防ぎ、
AtomVM の capability が増えた時点で必要条件を崩さず実装できる。
