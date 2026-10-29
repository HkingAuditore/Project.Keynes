# M5-36 release DLL 验证自动化（含 try/finally 的实证）

| 项目 | 内容 |
|---|---|
| 里程碑 | [§18.4](22-cell-program-cap-removal-plan-v3.md) debug/release 构建与真实测试 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | `verify_delivery.py --with-release` **VERIFY OK**；**恢复保护被实证是承重的** |

## 1. 补的是最后一件「只能手动」的事

release DLL 上的测试此前**手动做过 3 次**（M5-16 / M5-32 / M5-35 之前）。每次都要：

1. 备份 debug DLL
2. 把 release 内容复制到 debug 文件名
3. 跑夹具
4. 恢复备份

**任何一步被打断，工作区就停在一个「debug 文件名里装着 release 内容」的状态**，
而后续所有测试都会跑在错误的二进制上却看起来正常。

## 2. 实现要点

```python
try:
    ...把 release 字节写进 debug 文件名...
    problems += _run_fixture_list(RELEASE_FIXTURES, label='release')
finally:
    with open(DLL_DEBUG, 'wb') as f:
        f.write(debug_bytes)      # 内存里的副本，不是磁盘上可能被写坏的备份
    if sha16(DLL_DEBUG) != debug_hash:
        problems.append('FAILED TO RESTORE THE DEBUG DLL: ...')
```

| 设计 | 理由 |
|---|---|
| 备份在**内存**里 | 磁盘备份本身可能被中途写坏 |
| 恢复在 `finally` | 异常也要恢复 |
| 恢复后**校验哈希** | 不假设写入成功 |
| 哈希不对就报 `FAILED TO RESTORE` | 恢复失败必须是一条错误，不能只是日志 |
| 默认关闭（`--with-release`）| 它会改工作区，必须显式要求 |

## 3. 恢复保护被实证：我的脚本抛过异常，DLL 仍然恢复了

第一版把 `RELEASE_FIXTURES`（纯名字列表）传给了期望 `(name, expected)` 对的函数：

```
ValueError: too many values to unpack (expected 2)
  File ".../verify_delivery.py", line 214, in verify_release_build
=== CRITICAL: is the debug DLL restored? ===
debug: e8cbfded758a7da8  expect e8cbfded758a7da8   ← 恢复了
```

**异常发生在 DLL 已经被换掉之后。** 如果不是 `finally`，工作区会留在 release 内容 / debug 文件名的状态。

**这是「为什么恢复要放在 finally 而不是顺序代码里」的一次真实证明，不是我设想的场景。**

## 4. 校验器第二次抓到我自己的疏漏

修好类型后重跑，release 全部通过但冒出一条：

```
ideology_x9b_family_target_worker_test [release] ... (expected 0) MISMATCH
VERIFY FAILED (1):
  - ideology_x9b_family_target_worker_test [release]: expected 0/0, got 22/0
```

原因：那个夹具只在 `RELEASE_FIXTURES` 里，**不在 `EXPECTED_FIXTURES`**，
于是期望值回退成 0。

**这不是脚本的 bug，是期望表不完整——而校验器把它变成了一个会失败的检查。**
补上后两边共用同一张表。

## 5. 最终结果

```
=== fixtures (debug) ===    11 个全 OK
=== fixtures (release build) ===
swapped release build in (debug was e8cbfded758a7da8)
ideology_b5_idle_test                  [release] 9/0   OK
ideology_b7_wide_territory_test        [release] 23/0  OK
ideology_b11_domain_gate_test          [release] 9/0   OK
ideology_oracle_cross_check_test       [release] 19/0  OK
ideology_x1b_source_count_test         [release] 142/0 OK
ideology_content_test                  [release] 67/0  OK
ideology_x9b_family_target_worker_test [release] 22/0  OK
debug build restored (e8cbfded758a7da8)
VERIFY OK
```

**7 个 release 夹具的检查数与 debug 逐一相同。**

## 6. 用法

```
python Project/project-keynes/tools/ideology/verify_delivery.py               # 文档+覆盖率+内核+debug 夹具
python Project/project-keynes/tools/ideology/verify_delivery.py --with-release # 再加 release 夹具（会临时替换 DLL）
python Project/project-keynes/tools/ideology/verify_delivery.py --doc-only     # 只查 DLL 身份（秒级）
```

## 7. 局限

- release 只跑 **7 个** fixture（不是全部 11 个）：每多一个就多一次 DLL 替换窗口，
  而替换本身是风险。选的是**每个证据面各一个代表**（静默/宽领土/域边界/数值/源数/内容/家族）。
- 脚本**不验证**「release 与 debug 行为一致」这一更强命题——它只验证同一批检查数在两边都成立。
- 恢复失败时脚本会报错，但**不会**尝试第二次恢复。

## 8. 交付物

| 文件 | 说明 |
|---|---|
| `Project/project-keynes/tools/ideology/verify_delivery.py` | `--with-release` + `finally` 恢复 + 恢复后哈希校验 |
