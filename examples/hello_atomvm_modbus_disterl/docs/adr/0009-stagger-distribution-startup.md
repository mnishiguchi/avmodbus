# 0009: Client の distribution startup を遅らせる

## 背景

直前のtrafficがUART / RTU bufferに残り、ClientがServerより約1〜2秒先に起動すると、initial handshake中の
peer session change後に新しいconnection setupが始まらない場合があった。applicationはpingを再送するが、
`serial_dist`の新しいhandshake writeは観測されない。

AtomVM `v0.7.0-beta.0+git.8d3e051`の`net_kernel`は最初のconnect要求でpeerを
`{pending, undefined, DHandle}`として保持し、setup processがpeerと関連付く前に終了すると、そのpending entryを
終了processのPIDで除去できない経路がある。またpeer側のhalf-open connectionはtick timeoutまでlink managerを
占有し得る。

`serial_dist`の下でsetupだけを再実行するwrapperも実機評価したが、peer側のhalf-open stateを同時に解放できなかった。
Clientは`mark_nodeup` call timeout、Serverは後続の`net_tick_timeout`になったため、このwrapperは採用しない。

## 決定

- `proto_dist`はAtomVMの`:serial_dist`を直接使用し続ける
- Phase 2 Clientだけ、`net_kernel`とModbus UARTを開始する前にdefault 3,000 ms待つ
- ServerとPhase 1のdefault delayは0 msのままにする
- `MODBUS_START_DELAY_MS`でbuildごとに上書き可能にする
- この変更をconnection recoveryの修正ではなく、同時給電時の起動順序mitigationとして扱う
- AtomVM側のhalf-open cleanupを確認できるまではstartup delayなしの一般的なlivenessを保証しない

## 影響

Clientを約1.5秒先にresetした実機試験を2回行い、3秒delay後にはServerが先にreadyとなった。両runでgenuine
distribution handshakeとping/pong 3 / 3が完了し、pong timeoutは0だった。

delayは`net_kernel.start/2`より前に適用するため、AtomVMの7秒setup timerを消費しない。一方、ClientがServerより
3秒以上早く起動する場合、Serverのbootが通常より遅い場合、または確立途中のconnectionが別の理由でhalf-openに
なる場合はこのmitigationの範囲外である。
