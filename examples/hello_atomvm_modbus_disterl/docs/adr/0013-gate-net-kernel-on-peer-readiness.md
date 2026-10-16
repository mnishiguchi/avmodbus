# 0013: FC-100 peer readinessを確認してからnet_kernelを開始する

## 背景

[ADR 0009](0009-stagger-distribution-startup.md)では、Clientのdistribution startupを3秒遅らせてServer-first orderingを
作った。この固定delayは同時給電と約1.5秒のClient先行では有効だったが、Server起動が3秒以上遅れる場合を扱えない。
Server不在のまま`net_kernel`を開始すると、AtomVMの7秒setup timeoutより前にsetup processが終了し、
`{pending, undefined, DHandle}`が残って後続connectを開始できない場合がある。

## 決定

- Phase 2 Clientはdefaultで`DisterlProbe.ModbusUART`を`net_kernel`より先にopenする
- 有効なFC-100 responseを受信してpeer sessionを観測するまでphysical pollを継続する
- readinessを確認した同じadapter PIDを`serial_dist`の`uart_module.open/1`で再利用し、UARTをclose / reopenしない
- readiness確認後に`net_kernel`を開始し、固定startup delayのdefaultを0 msへ戻す
- `MODBUS_WAIT_FOR_PEER=false`でgateを無効化でき、`MODBUS_START_DELAY_MS`は追加の手動試験用として残す

## 影響

Server不在中はAtomVMのdistribution setup timerを開始しない。Clientを約70秒先に起動した実機runでは、Server起動後に
readiness確認、genuine distribution handshake、ping/pong 3 / 3を完了し、pong timeoutは0だった。

この判断は固定delayを採用したADR 0009を置き換える。ただしreadiness確認後のhandshake failureや確立済みconnectionの
任意のhalf-open stateを回復するものではなく、AtomVM `net_kernel`のpending cleanup問題は残る。
