# 0010: managed Server の supervision contract を統一する

## 背景

RTU / ASCII / TCP Server の tagged handle は direct startup には便利だが、Supervisor の child result と一致しない。

## 決定

- 各 managed Server は standard child specification を提供する
- supervision 用 start function は tagged handle から raw PID を返す
- `:name` は local atom registration とする
- lifecycle API は tagged handle、raw PID、name を受け付ける
- direct `start_link` の tagged result は後方互換のため維持する

## 影響

すべての transport を同じ方法で supervision tree に組み込める。
