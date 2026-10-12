# AtomVM artifact size の上限

この資料は、release や機能追加の前に firmware size を確認する開発者向けです。

AVModbus の AtomVM artifact regression は、pinned toolchain と既定 configuration で build した
`examples/hello_atomvm_modbus/sample_app.avm` を基準にします。
`MODBUS_MEASURE_MEMORY=true`、`MODBUS_HEALTH_INTERVAL_MS > 0`、または
`MODBUS_RESOURCE_PROBE=true` の diagnostic build は
この budget の対象外です。

- 基準値: 139,660 bytes
- 増加を検知する上限: 139,860 bytes
- 余裕: 200 bytes（約 0.1%）
- build SHA-256: `caf14c2fedee928f86721ee3084d2aa00ee22c1b8eeb592f9a1e60b9e1eaf41c`

UART broker の terminal error precedence を追加した結果、直前の 139,600-byte baseline から 60 bytes
増加しました。AtomVM compatibility check、host test、実 RS485 workflow を確認し、増分に従来と同じ
headroom を加えて budget を更新しています。

次の command は production artifact を再 build し、budget を超えた場合に失敗します。

```sh
cd examples/hello_atomvm_modbus
MIX_ENV=prod mix atomvm.size
```

artifact path と budget は、個別検証用に環境変数で上書きできます。

```sh
AVMODBUS_AVM_PATH=/tmp/sample_app.avm \
AVMODBUS_AVM_BUDGET_BYTES=139860 \
../../scripts/check_avm_size.sh
```

toolchain、compile-time configuration、example application の変更も artifact size に影響します。
上限を更新する場合は、意図した増加であることを確認し、新しい基準値、上限、build hash を
この文書と worklog に記録します。
