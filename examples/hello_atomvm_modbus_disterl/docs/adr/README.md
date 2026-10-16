# 設計判断記録

この実験で採用した長期的な設計判断を記録します。現在の利用方法は
[サンプル README](../../README.md)、構成は [アーキテクチャ](../architecture.md)、既知の制約は
[既知の制約](../limitations.md)、実機での調査結果は [作業記録](../worklog/README.md) を正とします。
判断を変更する場合は既存 ADR を書き換えず、新しい ADR で置き換えます。

## 追加と更新

- ファイル名は `NNNN-lowercase-kebab-case.md` とし、番号は連番にします。
- ADR には、判断が必要になった背景、採用する方針、その影響を簡潔に記録します。
- 実装手順や一時的な検証結果は ADR に含めず、サンプル README または `docs/worklog/` に置きます。
- 採用済みの判断を変更するときは既存 ADR を書き換えず、新しい ADR を追加して置き換え関係を記録します。
- ADR を追加したら、この一覧にもリンクを追加します。

## 一覧

- [0001: 実験を AVModbus core から分離する](0001-isolate-the-experiment.md)
- [0002: FC 100 上に stop-and-wait transport を構成する](0002-use-fc100-stop-and-wait-transport.md)
- [0003: virtual UART で serial_dist を再利用する](0003-adapt-serial-dist-with-a-virtual-uart.md)
- [0004: session ID で片側再起動後の transport を再同期する](0004-resynchronize-with-session-ids.md)
- [0005: GenServer の unsupported fallback callback を置き換える](0005-replace-unsupported-gen-server-fallbacks.md)
- [0006: protocol 上限と operating chunk size を分離する](0006-separate-protocol-and-operating-chunk-size.md)
- [0007: peer session の観測を stream synchronization boundary とする](0007-treat-peer-session-as-a-stream-boundary.md)
- [0008: virtual UART の outgoing queue を制限する](0008-bound-the-virtual-uart-queue.md)
