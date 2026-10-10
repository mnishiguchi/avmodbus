# 0005: AtomVM runtime target と host toolchain を分離して管理する

## 状態

採用

## 決定

現在の target と実機 baseline は次のとおりとする。

- AtomVM runtime compatibility target: `release-0.7` branch
- 実機 firmware baseline: `v0.7.0-beta.0+git.8d3e051`
- 2026-10-11 に監査した `release-0.7` head: `1f37255903c34909c06c83f866810ff9f9e43a8a`
- Erlang/OTP: `28.5.0.7`
- Elixir: `1.19.6-otp-28`
- host supported-API package: `{:atomvm, "~> 0.7.0-beta.0", optional: true, runtime: false}`

通常の実機 compatibility test と roadmap の acceptance evidence には、AtomVM が公開した
`v0.7.0-beta.0` ESP32-C5 image を使用する。source から build した runtime は、公式 artifact に含まれない
ELF / map が必要な native crash の upstream diagnostic にだけ使用し、その結果だけで compatibility item を
完了扱いにしない。

`:atomvm` package は runtime dependency ではなく、supported API / opcode metadata を提供します。
Mix task と packager は example の ExAtomVM dependency が提供し、この metadata を消費します。AtomVM source
repository の root は Mix project ではないため、`:atomvm` Hex dependency を
`github: "atomvm/AtomVM", branch: "release-0.7"` に置換しません。新しい metadata package が公開されるまでは
beta.0 package を固定し、device runtime compatibility は `release-0.7` source / firmware と別に追跡します。

## 理由

moving runtime branch、再現可能な実機 firmware、host metadata / tooling を同じ version label と誤認せず、
example の `mix atomvm.check` validation と device 上の runtime behavior をそれぞれ追跡できるようにするため。
また、通常 test の baseline を公式 artifact に固定することで、local ESP-IDF configuration に依存する差を
AVModbus の結果へ混入させないため。

## 再評価

`release-0.7` の head が更新されたときは socket / timer / supported API の差分を確認します。新しい AtomVM
prerelease / release と `:atomvm` package が公開されたときに firmware、metadata、Elixir / OTP version を
まとめて見直します。
