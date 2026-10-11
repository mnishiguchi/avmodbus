# 0011: 起動時の設定エラーは tagged error で返す

## 背景

起動 API ごとに validation と failure 形式が異なると、application と Supervisor が原因を安定して判定できない。

## 決定

- configuration error で raise せず `{:error, reason}` を返す
- non-list options は `:invalid_options`
- unknown option は `{:invalid_option, option}`
- invalid value は `:invalid_<name>_option`
- invalid handler は `:invalid_handler`
- UART、socket、process を確保する前に検証する
- direct / supervised startup で同じ error を返す

## 影響

boot policy と test が安定した reason を使え、不正設定による一時的な resource ownership を避けられる。
