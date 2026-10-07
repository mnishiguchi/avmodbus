# 0005: AtomVM prerelease と host toolchain の version を固定する

## 状態

採用

## 決定

現在の baseline は次のとおりとする。

- AtomVM: `v0.7.0-beta.0`
- Erlang/OTP: `28.5.0.7`
- Elixir: `1.19.6-otp-28`
- root library: `{:atomvm, "~> 0.7.0-beta.0", optional: true, runtime: false}`

`:atomvm` package は runtime dependency ではなく、target release の supported API / opcode metadata を使った build-time validation のために利用する。

## 理由

AtomVM target と host toolchain の組み合わせを明示し、`mix atomvm.check` で unsupported API を早期に検出できるようにするため。

## 再評価

新しい AtomVM prerelease / release を採用するときに firmware、metadata package、Elixir / OTP version をまとめて見直す。
