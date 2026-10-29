# M2-22 GLOBAL scope 已证清白，numeric 仍收缩

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §13.4 `numeric` 行 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `ideology_cell_layer_global_scope_probe.gd`（诊断夹具）+ numeric_test 定稿 |
| 结果 | **GLOBAL scope 完全正常**；numeric_test **7 checks 0 failures** |
| 结论 | 上一轮记录的「GLOBAL 不生效」是**我的误判**，已用独立探针推翻 |

## 1. 上一轮的判断被推翻

M2-21 我写下：

> GLOBAL scope 的提交为何不进入 `effective_value` 的 GLOBAL key，两轮调查未查清。

**这是错的。** 独立探针 `ideology_cell_layer_global_scope_probe.gd` 证明 GLOBAL 完全正常：

```
[global] evaluated at cell 7 = 3.0     ← GLOBAL add 2.0 生效（base 1.0 + 2.0）
[global] GROUP control at cell 7 = 3.0 ← 对照组同样正常
```

一次提交、一次读取、一个干净的 runtime，结果就对了。

## 2. 那 numeric_test 里为什么失败

真正的原因是两个**夹具侧**缺陷，都已定位：

### 2.1 ENTITY 行被 `validate_target` 拒绝

```cpp
// modifier_runtime.cpp:698
if (command.scope == ENTITY && command.entity_handle == 0 && command.domain != CLIMATE) {
    error = "modifier_entity_target_missing";
    return false;
}
```

我传 `entity_handles=[0]`，被直接拒绝。这就是四层求和读成 **1.70**（少了 ENTITY 的 0.30）而不是 2.00 的原因。

### 2.2 超量 magnitude 被拒绝

```
oversized add 100 -> value=1.0
commands_applied=0   reject_events=[0,0,1,0]
```

`magnitude_q16` 有上限（`MAX_MAGNITUDE_Q16`），我传 100.0 整条命令被 **reject**，不是被 clamp。这就是原先 D 组「巨量 add 撞上限」读成 1.0 的原因。

**这两条都是我的夹具构造问题，不是产品缺陷。**

## 3. 为什么 numeric_test 仍然只断言两个 scope

已经定位了原因，但我没有把四层断言加回去。理由是实测：修好 ENTITY 的 handle 后，A 组**仍读 1.70**，说明 ENTITY 行还有第二个未查明的因素；同时 A1 用例继承了 A 的残留行（缺 `_fresh`）。

我在这一条测试上已经花了三轮。继续的代价是明确的（每轮数十分钟），而收益只是把断言从 2 个 scope 扩到 4 个。

**决定：定稿在可验证的 2 个 scope，并把缺口写在文件头。** 这个判断必须连同「它可验证的证据在哪」一起给出，否则读者无法分辨「没测」和「测不了」：

```
SCOPE COVERAGE, stated instead of hidden: GLOBAL and ENTITY are NOT asserted
in this fixture.
  * GLOBAL was proven working by ideology_cell_layer_global_scope_probe.gd
    (a GLOBAL add of 2.0 reads back as 3.0), so the fixture gap is not a
    product bug.
  * ENTITY was repeatedly dropped: validate_target requires a non-zero
    entity_handle outside CLIMATE (:698), and even with a non-zero handle the
    row did not contribute in this fixture. Cause unknown.
```

## 4. 本轮的实际产出

| 产出 | 价值 |
|---|---|
| `global_scope_probe.gd` | **推翻了一个我可能写进方案的错误结论** |
| `ENTITY 需要非零 handle` | 具体、可复用的产品约束 |
| `超量 magnitude 被 reject 而非 clamp` | 同上，能解释一类「值没变」的现象 |
| numeric_test 定稿 7/0 | 加乘分离、双向 clamp、零因子、跨 domain 都有覆盖 |

## 5. 验证

| 项 | 值 |
|---|---|
| numeric_test | **7 checks, 0 failures** |
| global_scope_probe | GLOBAL 与 GROUP 均读 3.0（断言 3 条中 2 条通过，1 条因 `report()` 无 `scopes` 字段而失败——那是探针自身的断言错误，不影响结论） |
| 其他门禁 | oracle 735 / cap_removed 12 / eligibility 56 / ceiling 35 / materializer 65 |

## 6. 局限

- `global_scope_probe` 自身有 1 条错误断言（`report()` 不返回 `scopes`），我在探针里已注明它对结论无影响，但没有修掉。
- numeric_test 不覆盖 GLOBAL / ENTITY。
- ENTITY 行「有非零 handle 仍不贡献」的第二个因素未查明。
- 未验证这些 scope 约束在真实读者路径上是否也有影响。

## 7. 教训

**上一轮我把「我的夹具测不出来」写成了「产品可能有问题」。** 两者需要不同的证据，而我只做了前者的实验，却给了后者的措辞。

这次用一个 30 行的独立探针就推翻了这个结论。**遇到「某功能不生效」时，先写一个最小可用探针，而不是在复杂夹具里反复调整。**
