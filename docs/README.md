# ドキュメント

AVModbus のドキュメントは、利用者向けの説明、開発者向けの設計資料、検証記録に分けています。

## 利用者向け

- [Modbus の基礎](modbus-basics.md) — Modbus と RS485 の違い、基本用語
- [はじめ方](getting-started.md) — AVModbus の追加、UART の設定、最初の読み書き
- [実機チュートリアル](../examples/hello_atomvm_modbus/README.md) — XIAO ESP32-C5 と HW-519 を使った通信

## 開発者向け

- [アーキテクチャ](architecture.md) — コンポーネントの責務と境界
- [開発者ガイド](development.md) — 高度な設定、テスト、相互運用確認
- [動作確認済みの構成](compatibility.md) — 検証した runtime、機器、外部実装
- [既知の制約](limitations.md) — AtomVM と AVModbus の制約
- [ロードマップ](roadmap.md) — 現在の課題と対象外の項目
- [設計判断記録](adr/README.md) — 長期的に維持する設計判断

`development/` には、実機試験、リソース計測、障害調査、リリース確認などの再現可能な記録を置きます。
現在の利用方法は利用者向け資料を正とし、調査の経緯や過去の測定値は `development/` に残します。

## 実験

- [Modbus RTU 上の distributed Erlang](../examples/hello_atomvm_modbus_disterl/README.md) —
  custom Function Code `100` を carrier として使う standalone example
- [実験用ドキュメント](../examples/hello_atomvm_modbus_disterl/docs/README.md) —
  アーキテクチャ、制約、ロードマップ、ADR、実機 worklog

この実験では genuine distributed Erlang の動作を実機確認していますが、carrier と
virtual UART adapter は AVModbus の public API ではありません。実験の lifecycle と記録は
サンプル配下で管理します。

## 更新方針

- 本文は日本語を基本とし、API 名、プロトコル名、正式な技術用語は必要以上に翻訳しません。
- ファイル名は小文字の kebab-case とします。ディレクトリの入口となる `README.md` は例外です。
- 同じ説明を複数のページへ複製せず、正となるページへリンクします。
- 実測値には日付、実行環境、機器、設定、再現方法を添え、確認済みの範囲と一般的な保証を区別します。
- ファイルを移動した場合は、リポジトリ内のリンクと `mix.exs` の ExDoc 設定を更新します。
- 長期的な設計判断を変更する場合は、[ADR の更新方針](adr/README.md#追加と更新)に従います。
