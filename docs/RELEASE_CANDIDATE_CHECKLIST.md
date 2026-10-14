# AVModbus リリース候補チェックリスト

この checklist は将来 release candidate を作る際の判断材料です。**Hex 公開は現時点の完了条件ではありません**。
実行していない検証項目は `- [ ]` のままにします。

## API とドキュメント

- [ ] public Client / Server の signature、option、error tuple が example / ExDoc と一致する
- [ ] 同期 / 非同期 request admission の動作が文書と test で一致する
- [ ] lifecycle ownership と TCP `max_buffer` の範囲が実装と一致する
- [ ] 対象 runtime で使えない機能（mutual TLS など）が明示的に失敗し、文書化されている
- [ ] `CHANGELOG.md` と `mix.exs` の release version が一致する

## 再現可能な host gate

```sh
mix deps.get
mix format --check-formatted
mix test --cover
python3 -m unittest discover -s scripts -p 'test_*.py'
```

- [ ] host tests と property tests が通過する
- [ ] release 候補 commit で CI の `test` / `interoperability` jobs が通過する
- [ ] 固定 seed（`12345`、`54321`）の両方で pinned `pymodbus` / installed `libmodbus` interoperability が通過する
- [ ] 不安定な失敗を単に再実行せず、release 前に原因を調べる

## AtomVM / hardware gate

- [ ] supported AtomVM reference で example の `MIX_ENV=prod mix atomvm.check` variants が通過する
- [ ] `MIX_ENV=prod mix atomvm.size` が artifact budget 内に収まる（または変更理由を記録する）
- [ ] TCP loopback resource probe log を保存・CSV 化し、過去の baseline と比較する
- [ ] resource probe が `ok` で、process / heap が回復し、runtime warning が記録されている
- [ ] 正確な board / firmware / adapter を記録した実機で RTU/RS485 workflow が通過する
- [ ] [互換性表](COMPATIBILITY_MATRIX.md)には実際に検証した組み合わせだけを記載する

## 配布するときだけ行う packaging

- [ ] versioning 方針と documentation URL を確認する
- [ ] `mix hex.build` の内容に必要な file、documentation、license が含まれることを確認する
- [ ] repository 内 example だけでなく、別 application から package を利用して確認する
- [ ] tag / release candidate 名を決め、release notes を用意する
- [ ] publish 操作の前に明示的な承認を得る

この checklist の実行によって Hex への publish や GitHub release の作成を自動では行いません。
