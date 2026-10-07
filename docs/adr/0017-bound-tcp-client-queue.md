# 0017: TCP client の待機 queue を制限する

## 状態

採用

## 背景

TCP client の `:max_pending` は wire 上で response を待つ request 数を制限する一方、
それを超えた request の待機 queue は無制限だった。長い timeout を持つ request が集中すると、
memory が限られる AtomVM device で client process の heap と timer が増え続ける。

## 決定

- TCP client に `:max_queue` option を追加する
- default は 64、範囲は `0..65_536` とし、明示的な `:infinity` も許可する
- `:max_queue` は `:max_pending` とは別に、まだ送信されていない request 数を制限する
- pending slot が空いていれば `max_queue: 0` でも request を直接送信できる
- queue が満杯なら synchronous / asynchronous request を `{:error, :queue_full}` で即時完了する
- queue の request を追い出さず、capacity が戻れば新しい request を再び受け付ける
- `:queue_full` は retry 対象にしない

## 理由

deadline だけでは、長い timeout を指定した大量の request が同時に保持されることを防げない。
固定上限と明示的な overload error により、caller は backpressure を実装でき、既存の request の
exactly-once result と deadline を維持できる。`:infinity` は無制限 queue が必要な
host application のために残す。

## 影響

default 設定では pending 4 件と waiting 64 件までを client が保持する。上限を超えた request は
wire に送られないため、write の実行有無は曖昧にならない。serial client の mailbox 制御は別の
設計課題とし、この決定の対象には含めない。
