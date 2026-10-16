# Initial-handshake liveness と起動順序mitigation — 2026-10-16

## 目的

4 KiB active-transfer recoveryの準備中に再現した、initial handshake中のsession change後にconnection retryが
進まない問題を調査する。transportだけの修正で安全に復旧できるか確認し、できない場合は再現条件を狭める
mitigationと残るblockerを明確にする。

## AtomVM sourceの調査

対象はboardで使用中のAtomVM `v0.7.0-beta.0+git.8d3e051`である。同commitの`net_kernel.erl`と
`serial_dist.erl`を確認した。

最初のremote sendで`net_kernel`が`ProtoDist:setup/5`を呼ぶと、connection mapには
`{pending, undefined, DHandle}`が入る。handshake processが`dist_util`から`mark_pending/4`を呼んだ後はPIDが入るが、
それ以前にsetup processが終了した場合、`'EXIT'` handlerは`undefined`と終了PIDを一致させられずentryを除去しない。
後続のconnect requestは既存pending entryの`DHandle`だけを更新し、新しい`ProtoDist:setup/5`を呼ばない。

このsource pathは、application ping retryだけが続き、新しいhandshake writeが始まらなかった実機logと整合する。
ただしexampleのhost testはAtomVM `net_kernel` processを動かしていないため、これはsource inspectionと実機logに基づく
原因候補であり、AtomVM unit testによる確定ではない。

## 棄却したsetup retry wrapper

`:serial_dist`の全callbackをdelegateし、outgoing setup processの早期終了だけをmonitorして再実行する薄いwrapperを
試作した。hostではearly failure後のretry policyをtestでき、43 testsが成功し、PackBEAMも完了した。

しかし約1.5秒Client先行で実機試験すると、Clientのhandshakeは`net_kernel`への`mark_nodeup` callで5秒timeoutに
なった。

```text
exit: {timeout,{gen_server,call,[...,{mark_nodeup,b@modbus.local,...},5000]}}
```

Server側にはhalf-open connectionが残り、約75秒後に`net_tick_timeout`になった。setupだけを再実行してもpeer側の
busy link managerとhalf-open distribution stateを原子的に解放できないため、安全なexample-local recoveryではないと
判断し、wrapperのcode、test、設定をすべて撤回した。

## 採用したmitigation

Phase 2 Clientのdefault `MODBUS_START_DELAY_MS`を3,000 msとし、`net_kernel`とModbus UARTをServerより後に開始する。
ServerとPhase 1のdefaultは0 msである。delayはdistribution setup timer開始前に適用される。

同じ2台のXIAO ESP32-C5を使い、`tio` scriptでClientを先にresetし、約1.5秒後にServerをresetするrunを2回行った。

| run | first pong RTT | steady RTT | ping/pong | pong timeout |
| --- | ---: | ---: | ---: | ---: |
| 1 | 4,325 ms | 1,441 / 1,442 ms | 3 / 3 | 0 |
| 2 | 4,330 ms | 1,443 / 1,442 ms | 3 / 3 | 0 |

両runでClientはresetから3秒後にvirtual UARTをopenし、その時点ではServerが既にreadyだった。genuine distribution
handshake、remote process messaging、接続後のmulti-chunk writeはすべて完了した。

最終firmwareを両boardへflashした後、ready済みServerに対してClientだけをresetするregressionも行った。ping/pongは
3 / 3、RTTは3,560 / 1,440 / 1,442 ms、pong timeoutは0で完了した。

## 結論

3秒delayは同時給電と今回の約1.5秒Client先行条件を安定したServer-first orderingへ変えるmitigationとして採用する。
これはAtomVMのpending connection cleanupを修正せず、Clientが3秒以上先行する条件や任意のhalf-open failureからの
recoveryを保証しない。

根本対応にはAtomVM側で、setup processがpeerへ関連付く前に終了した場合のpending entry cleanupと、両endpointの
link managerを含むretry lifecycleを検証する必要がある。exampleはその修正をvendorせず、`:serial_dist`を直接再利用する。

## Upstream follow-up

2026-10-16にAtomVM upstreamを再確認した。`release-0.7`の
[`18b35870`](https://github.com/atomvm/AtomVM/commit/18b35870a0be75c42892db9a0762e8c7a7d61323)と`main`の
[`3a9ea46b`](https://github.com/atomvm/AtomVM/commit/3a9ea46b8cf28066caf126c46119dc58f950de5f)では、どちらも
`net_kernel`の最初のoutgoing connectが`ProtoDist:setup/5`の返すPIDを使用せず、connection mapへ
`{pending, undefined, DHandle}`を保存する。

一方、`ProtoDist:setup/5`はlinkされたsetup processのPIDを返す。返されたPIDをpending entryへ保存すれば、processが
`mark_pending/4`より前に終了しても既存の`'EXIT'` handlerがentryを除去できる。これはlocal pending cleanupの最小修正候補で
ある。ただし、実機で観測したpeer側のhalf-open controllerも同じretry中に解放されるかは、この変更だけからは確定できない。

次のupstream検証は次の順で行う。

1. setup processが`mark_pending/4`より前に終了する条件をAtomVM testで作り、次のconnectが新しいsetupを開始することを確認する
2. 修正版system libraryで両boardをbuildし、Clientの`MODBUS_START_DELAY_MS=0`かつClientを3秒以上先行させる
3. peer側controllerの終了、新しいhandshake、ping/pongまでを複数runで確認する
4. initial setup前の起動順序には、固定delayを置き換えるFC-100 peer readiness gateを実機検証する

この修正候補はAVModbusやFC-100 transportの責務ではないため、exampleへ`net_kernel`を複製しない。

4は同日に実施し、約70秒Client先行でもping/pongへ進むことを確認した。結果とdefault変更は
[peer readiness gate実機検証](2026-10-16-peer-readiness-gate.md)と
[ADR 0013](../adr/0013-gate-net-kernel-on-peer-readiness.md)に記録している。

1〜3のfollow-upも同日に実施した。`ProtoDist:setup/5`の返すPIDを最初のpending entryへ保存する修正と、early setup
EXIT後に次のconnectが新しいsetupを開始するAtomVM testを追加した。修正版boot libraryではreadiness後の40-response faultから
ping/pongへ復旧し、旧boot libraryでは同一条件でapplication retryだけが続いた。詳細は
[AtomVM setup PID cleanupとhandshake retry実機A/B](2026-10-16-atomvm-setup-retry.md)に記録している。
