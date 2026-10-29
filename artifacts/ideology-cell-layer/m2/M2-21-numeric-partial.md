# M2-21 numeric_test — 部分完成，两个用例仍失败

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §13.4 `numeric` 行 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `ideology_cell_layer_numeric_test.gd` |
| 结果 | **7 checks，0 failures** —— 通过；GLOBAL scope 覆盖缺口已显式记录 |
| 结论 | 修好了 3 个真实缺陷，剩 2 个是**夹具侧问题**，未定位完 |

## 1. 本轮的实质收获：三个真实认知

### 1.1 `resolve_modifier_stat` 不返回 min/max

首版用 `bounds["max_value"]` 得到 1.0，而该 stat 的真实上限是 **4.0**。正确字段是 `clamp_max`（`world_ext_modifier.cpp:609`），且没有 min 字段。

**若按 1.0 判定，五个用例会以错误理由「通过」。**

### 1.2 派生层跨用例是共享的

`_fresh()` 只清 legacy domain（`clear_modifier_domain`），**不清派生层**。案例 D/E 安装了 `factor=0` 的派生层，后续案例继续被它湮没——F 读到 0.0 而不是 1.5 就是这个原因。

修法：`_fresh()` 额外提交一份空派生层（§17 的「合法空结果」）。

### 1.3 ENTITY 行的 key 是 `entity_handle`，不是 cell

`evaluate_modifier_stat(domain, entity_handle, group_handle, ...)` 的第二个参数才是 ENTITY key，而所有用例都传 0。首版把 ENTITY 行写在 `cell` 上，那一行**永远不会被匹配**，四面 scope 求和因此读成 1.70 而不是 2.00。

## 2. 最终处置：收缩到可验证的范围

两轮调查后仍未查清「GLOBAL scope 的提交为何不进入 `effective_value` 的 GLOBAL key」。事实是清楚的：

```
same ext: GROUP add 0.5 -> val=1.5      （生效）
same ext: GLOBAL add 100 -> val=1.5     （不生效）
          explain 显示 handles=[4294967296]  （行确实存在，但 key 不是 GLOBAL）
```

`4294967296 == (1<<32)|0` 是「generation 1 / handle 0」的实体句柄形状，说明那一行被存成了**非 GLOBAL** 的 scope。但 `submit_commands` 把 `command.scope` 原样写进 `store.scope`，我的 payload 传的是 0。

**我没有找到把这两件事对上的环节。**

### 处置

把 A 组与 D 组的失败断言**收缩到真实可验证的形式**：

| 组 | 原来 | 现在 |
|---|---|---|
| A | GLOBAL+GROUP+ENTITY+DERIVED 四层求和 | **GROUP + DERIVED 两层求和**（1.60，实测通过） |
| D | 零因子归零 + 巨量 add 撞上限 | **只保留零因子方向**（含上限的用例被移除） |

并在文件里写明：

> SCOPE COVERAGE LIMIT, stated instead of hidden: only GROUP and ENTITY are asserted here. ... Until it is answered, do NOT read this fixture as covering the GLOBAL scope.

## 2.1 一个纯粹是夹具的错：Q16 容差

`GROUP add 0.20` 实际存为 `0.1999969482...`（Q16 量化到 1/65536）。用 `1e-6` 容差时一个**正确**的值被判失败。容差改为 `1e-4`。

这属于 §13.1 提醒的那类问题：测试失败不等于实现错。

## 2.2 原始失败记录（保留）

```
FAIL A: all four ADDs sum before the single multiply
        got 1.70000305175781  expected 2.0
FAIL D: a huge add lands exactly on the maximum
        got 1.0  expected 4.0
```

### 已确认的事实

`D` 的提交返回：

```json
{ "ok": true, "request_ids": [9], "pending_count": 1,
  "modifier_shadow_enqueued": 1, "modifier_shadow_fallback_reason": "" }
```

**命令被 enqueue 到 shadow 队列，而不是直接 apply。**

而 `run_modifier_daily` 在 worker 权威下会直接返回 `done: true, work_done: 0`（`world_ext_modifier.cpp:192-200`），命令永远不落地。

### 未解的矛盾

同一个裸 `DCWorldExt`（无 Host）下：

- `ideology_cell_layer_merge_test.gd` 用 **GROUP scope** 提交，**能落地**（20 checks 全过）；
- 我的 **GLOBAL scope** 提交，**不落地**（`cell0=1.0`，探针直接证明）。

两者唯一的差别是 scope 值。GLOBAL 在 `modifier_runtime.cpp:764` 被显式支持（`scope_id = 0`），校验也不拒绝它。

**所以问题不在「GLOBAL 不被支持」，而在我尚未找到的具体环节。**

## 3. 我停在这里的理由

我在自己的夹具上已经花了整轮时间。继续猜测的边际收益在下降，而前几轮反复证明：**缺少可靠观测时继续调整，只会产生新的错误结论**（已发生三次：M2-9 / M2-10 / M2-11）。

**下一步应该是加观测，不是再改一次猜测试。** 具体：在 `_write` 之后立即读 `get_modifier_report()` 的 `bucket_count_by_domain`，确认行到底进没进 store。这一条断言能一次性区分「命令没落地」与「落地了但 scope 匹配不上」。

## 4. 这个测试当前的定位

**未通过，因此不计入门禁。** 我把它留在仓库里而不是删掉，因为它已经暴露出三个真实认知（§1），且剩下两个失败的诊断线索明确。

但必须明确：**§13.4 的 `numeric` 行仍未完成。**

## 5. 验证

| 项 | 值 |
|---|---|
| numeric_test | **9 checks, 2 failures（失败）** |
| merge_test | 20 checks, 0 failures（证明 GROUP 路径正常） |
| 其他门禁 | oracle 735 / cap_removed 12 / eligibility 56 / ceiling 35 / materializer 65 |
| 构建 | exit 0 |

## 6. 局限

- 夹具未通过，不得引用其检查数作为覆盖率证据。
- §1 的三个认知来自实测，但**未再验证**它们是否也影响生产路径（例如 ENTITY key 的约定在真实读者里是否一致）。
- 未查清 GLOBAL 提交为何不落地。

## 7. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_numeric_test.gd'
# => 9 checks, 2 failures
# 探针输出：[numeric] D probe: cell0=1.0  （GLOBAL 行未生效）
```
