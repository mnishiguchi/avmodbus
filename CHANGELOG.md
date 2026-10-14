# 変更履歴

AVModbus はまだ公開リリースを行っていません。以下は初回リリースに向けた変更です。

## Unreleased

### 追加

- AtomVM 向けの Modbus RTU / ASCII / TCP Client・Server
- Coil・Register の読み書き、診断、デバイス情報などの Modbus 機能
- UART 通信、再接続、タイムアウト、読み取り処理のリトライ
- `pymodbus`・`libmodbus` との相互運用テスト、ESP32-C5 での実機検証

### 改善

- 通信中のエラーや切断からの復旧処理を改善
- TCP 接続ごとの受信バッファー、終了処理、リソース管理を強化
- AtomVM のメモリ使用量とファームウェアサイズの計測方法を整備
