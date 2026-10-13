# AtomVM artifact size の上限

この資料は、release や機能追加の前に firmware size を確認する開発者向けです。

AVModbus の AtomVM artifact regression は、pinned toolchain と既定 configuration で build した
`examples/hello_atomvm_modbus/sample_app.avm` を基準にします。
`MODBUS_MEASURE_MEMORY=true`、`MODBUS_HEALTH_INTERVAL_MS > 0`、または
`MODBUS_RESOURCE_PROBE=true` の diagnostic build は
この budget の対象外です。

- 基準値: 147,536 bytes
- 増加を検知する上限: 147,736 bytes
- 余裕: 200 bytes（約 0.1%）
- build SHA-256: `7a995704650c1bd5e7830d6b51c010a0a05b0ecd8644a32cbb4652a59aa39e8a`

TCP listener の handler fallback ownership、bounded shutdown、handoff failure cleanup を追加した結果、
直前の 144,508-byte baseline から 3,028 bytes 増加しました。AtomVM compatibility check、host test、
pymodbus interoperability、短時間 soak、ESP32-C5 resource probe と実 RS485 smoke test を確認し、
増分に従来と同じ headroom を加えて budget を更新しています。

次の command は production artifact を再 build し、budget を超えた場合に失敗します。

```sh
cd examples/hello_atomvm_modbus
MIX_ENV=prod mix atomvm.size
```

artifact path と budget は、個別検証用に環境変数で上書きできます。

```sh
AVMODBUS_AVM_PATH=/tmp/sample_app.avm \
AVMODBUS_AVM_BUDGET_BYTES=147736 \
../../scripts/check_avm_size.sh
```

toolchain、compile-time configuration、example application の変更も artifact size に影響します。
上限を更新する場合は、意図した増加であることを確認し、新しい基準値、上限、build hash を
この文書と worklog に記録します。
