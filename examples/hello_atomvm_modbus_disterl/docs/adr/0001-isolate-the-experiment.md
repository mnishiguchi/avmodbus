# 0001: 実験を AVModbus core から分離する

## 背景

distributed Erlang over Modbus RTU は実現可能性を調べる段階にあり、AVModbus の一般的な用途とは
異なる transport 制御や AtomVM 固有の distribution 設定を必要とする。

## 決定

- 実験を `examples/hello_atomvm_modbus_disterl/` の独立した Mix project とする
- AVModbus は local path dependency として利用する
- custom Function Code の handler と transport 状態はサンプル側に置く
- 一般用途として必要だと確認できるまで `lib/avmodbus/` を変更しない

## 影響

実験的な wire format、再送制御、AtomVM 設定が AVModbus の公開 API と既存サンプルに影響しない。
一方、実験で得た処理をライブラリへ移す場合は、別途 API と互換性を設計する必要がある。
