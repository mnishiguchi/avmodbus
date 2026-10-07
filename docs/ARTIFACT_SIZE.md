# AtomVM artifact size budget

AVModbus の AtomVM artifact regression は、pinned toolchain と既定 configuration で build した
`examples/hello_atomvm_modbus/sample_app.avm` を基準にします。
`MODBUS_MEASURE_MEMORY=true`、`MODBUS_HEALTH_INTERVAL_MS > 0`、または
`MODBUS_RESOURCE_PROBE=true` の diagnostic build は
この budget の対象外です。

- baseline: 126,020 bytes
- regression budget: 126,200 bytes
- headroom: 180 bytes（約 0.1%）
- build SHA-256: `ee7c4f5fb6cacdd0595ac52fe13a19bf13bf28b04463e25fc61516ab540ff8ae`

AtomVM で利用できない `Map.pop/2` を TCP client response / server eviction path から除去した結果、
baseline は 140 bytes 増加しました。実機で TCP response path を確認した上で、同じ 180-byte
headroom を維持するよう budget を更新しています。

次の command は production artifact を再 build し、budget を超えた場合に失敗します。

```sh
cd examples/hello_atomvm_modbus
MIX_ENV=prod mix atomvm.size
```

artifact path と budget は、個別検証用に環境変数で上書きできます。

```sh
AVMODBUS_AVM_PATH=/tmp/sample_app.avm \
AVMODBUS_AVM_BUDGET_BYTES=126200 \
../../scripts/check_avm_size.sh
```

toolchain、compile-time configuration、example application の変更も artifact size に影響します。
budget を更新する場合は、意図した増加であることを確認し、新しい baseline、budget、build hash を
この文書と worklog に記録します。
