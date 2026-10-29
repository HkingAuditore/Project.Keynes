# M5-35 交付证据自检脚本 + 负向对照

| 项目 | 内容 |
|---|---|
| 里程碑 | [§15.1](22-cell-program-cap-removal-plan-v3.md)「一个问题没有证据关闭时不能仅把状态改成基本完成」|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **`verify_delivery.py`**：把可复算的声明全部重新推导；**负向对照通过** |

## 1. 为什么需要它

上一轮发现 **DLL 身份漂移**：文档写着 debug `5f73e78d…` / release `5f3c44ab…`，
而实际文件是 `e8cbfded…` / `ed583385…`——**家庭校验修复之后代码改了，记录没跟上**。

**没人发现，直到有人手工去读二进制。** 这正是「记录写了但之后又改了代码」的失效方式。

所以写一个脚本，把**能重新推导的声明**都重新推导一遍。

## 2. 它检查什么

| 检查 | 方法 |
|---|---|
| **DLL 身份** | 从三份文档的 `\| debug \| \`hash\` \|` / `\| release \| \`hash\` \|` 表格行取出**当前声明**，与文件实测比对 |
| **覆盖率** | 跑 `m1_backend_coverage.py --check`，要求出现 `actual=265 expected=265` |
| **内核** | 跑 `.codex-tmp/rebuild_test.exe`，要求 0 失败 |
| **夹具** | 跑 11 个奠基夹具，**逐个要求检查数等于记录值且 0 失败** |

**关键设计：只把表格行当作「当前声明」。**
里程碑日志里合法地记录了**过去**的哈希（`35e62122…`、`c073f81a…`）；
把它们也当声明会让校验永远报错。脚本单独统计这些「历史哈希」（本轮 8 个）但不对它们下判断。

## 3. 实测

```
debug   on disk: e8cbfded758a7da8   claimed: e8cbfded758a7da8
release on disk: ed5833856197e018   claimed: ed5833856197e018
(historical hashes elsewhere in the documents: 8 -- not treated as claims)

=== coverage gate === 6 checks, 0 failures
=== kernel ===       103 checks, 0 failures
=== fixtures ===      11 个全部 OK（9/23/18/16/9/19/6/142/6/19/67）

VERIFY OK
```

## 4. 负向对照（关键）

**一个不会失败的校验是装饰。** 所以我把 release 的声明改成 `deadbeefdeadbeef`：

```
release on disk: ed5833856197e018   claimed: deadbeefdeadbeef
VERIFY FAILED (1):
  - the documents claim release=['deadbeefdeadbeef'] but the file is ed5833856197e018
exit=1
NEGATIVE CONTROL PASSED -- the verifier noticed
```

恢复后 `exit=0`。

**它真的会失败，而且报的是精确的不匹配。**

## 5. 途中的一处路径 bug

第一版 `ROOT` 只上溯 **3 层**，于是 PROJECT 变成 `Project/Project/project-keynes`，
两个 DLL 都「不存在」。

**如果不跑一次，这个脚本会永远报「DLL 缺失」而看起来像在认真工作。** 已修（4 层）。

## 6. 它不检查什么（写清楚）

| 不检查 | 理由 |
|---|---|
| §18 的 **14 / 3 / 11** 划分 | 那是**对证据质量的判断**，不是测量 |
| 性能数字 | 需要预热与多批次，不适合放进一个快速校验；且机器负载会漂移 |
| release DLL 上的测试 | 需要先把 release 内容换到 debug 文件名，有副作用；本轮仍手动做（M5-16/M5-32/M5-35 之前各做过一次）|
| 里程碑报告里的历史哈希 | 它们是历史记录，不是当前声明 |

**这个脚本能保证「记录与工作区一致」，不能保证「结论正确」。** 两者不要混为一谈。

## 7. 用法

```
python Project/project-keynes/tools/ideology/verify_delivery.py            # 全量
python Project/project-keynes/tools/ideology/verify_delivery.py --doc-only # 只查身份（秒级）
```

`GODOT_EXE` 环境变量可覆盖 Godot 路径。

## 8. 交付物

| 文件 | 说明 |
|---|---|
| `Project/project-keynes/tools/ideology/verify_delivery.py` | 交付证据自检，含负向对照验证 |
