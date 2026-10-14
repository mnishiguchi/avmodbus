# 動作確認済みの構成

この表には、**実際に試した組み合わせ**だけを記録しています。
「未検証」は「動作しない」という意味ではありません。

## 確認済み

| 接続するもの | 通信方式 | 機器・バージョン | 確認できたこと |
| --- | --- | --- | --- |
| AVModbus ↔ AVModbus | RTU / RS485 | XIAO ESP32-C5 × 2、HW-519 × 2、AtomVM `v0.7.0-beta.0+git.8d3e051` | 2026-10-10 に 5 分間・1,623 件成功、失敗 0。後日、読み書きの試験も実施 |
| AVModbus ↔ `pymodbus` | TCP / RTU / ASCII | ホスト上の TCP・仮想シリアル、`pymodbus` 3.15.0 | Client / Server の両方向でテスト |
| AVModbus ↔ `libmodbus` | TCP / RTU | ホスト上の TCP・仮想シリアル、`libmodbus` 3.1.11 | Client / Server の両方向でテスト |

外部実装とのテストは 2026-10-14 に固定 seed 2 種類でローカル実行しました。
**GitHub Actions 上での成功は、この記録だけでは確認できません。**
ホスト上の仮想シリアル試験は、実機の RS485 試験とは区別しています。

## まだ確認していない構成

- HW-519 以外の RS485 トランシーバーや USB-RS485 アダプター
- 市販の Modbus RTU 機器
- 3 台以上をつないだ RS485 のマルチドロップ構成
- 別の AtomVM 対応基板や新しいファームウェア

## 新しい結果を追加するとき

日付、AVModbus・AtomVM のバージョン、機器、配線、通信設定、試した操作、
成功・失敗の件数、再現手順を記録してください。
メモリ測定やエラーログがあれば一緒に残します。
実験結果の背景は
[開発記録](https://github.com/mnishiguchi/avmodbus/blob/main/docs/development/worklog.md)
を参照してください。
