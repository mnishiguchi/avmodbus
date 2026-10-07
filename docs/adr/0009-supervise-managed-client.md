# 0009: managed client を OTP supervision と両立させる

## 状態

採用

## 背景

AVModbus の managed client は serial と TCP の validation policy を区別するため、
`start_link` から tagged handle を返していた。OTP supervisor の child start function は
`{:ok, pid}` を返す必要があり、この handle をそのまま child result にできない。
一方、既存 application と low-level UART API の互換性も維持したい。

## 決定

- client の child specification は supervision 専用 start function を使う
- supervision 専用 start function は既存 `start_link` の tagged handle から PID を返す
- 全 managed client API は tagged handle に加えて raw PID と registered local name を受け付ける
- raw PID / name では client process に serial / TCP kind を問い合わせ、既存 validation path に委譲する
- `:name` option は local atom registration とする
- standard lifecycle API として `stop/1` を追加し、既存 `close/1` も維持する

## 理由

既存の AtomVM application を壊さず、通常の OTP supervision tree と `start_supervised!/2` から
client を直接扱える。serial と TCP の unit policy は引き続き一つの validation path に保たれる。
