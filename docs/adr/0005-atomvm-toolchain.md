# 0005: AtomVM runtime target と host toolchain を分離して管理する

## 背景

runtime branch、実機 firmware、host の API metadata、Erlang / Elixir toolchain は更新周期と用途が異なる。

## 決定

- compatibility target は AtomVM `release-0.7` とする
- 通常の実機検証には公式 `v0.7.0-beta.0` ESP32-C5 image を使う
- source build は matching ELF / map が必要な upstream crash 調査に限定する
- `:atomvm` dependency は supported API metadata 用の build-time dependency とし、runtime へ含めない
- host toolchain は `.tool-versions`、dependency version は `mix.exs` / `mix.lock` を正とする

## 再評価

AtomVM の新しい公式 image または metadata package が公開されたときに、runtime behavior と host validation を
別々に確認して更新する。
