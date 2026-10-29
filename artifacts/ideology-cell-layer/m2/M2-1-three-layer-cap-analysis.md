# M2-1 the 32 cap is enforced in three coupled layers — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) 前置分析 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 性质 | 范围分析。**发现方案遗漏了一整层 32 的实现** |
| 结论 | 32 在**代码常量、内容参数、实例截断**三处联动；只改其一会无效或被拒绝 |

## 1. 方案遗漏的一层

我扫描了全部 `SELECTOR_MAX_CELLS` 的使用，得到 **13 处代码**。方案正文**一次都没有提到它**（`grep SELECTOR_MAX_CELLS` 在方案里 0 命中）。

当前 32 的实现分散在三层：

| 层 | 位置 | 作用 |
|---|---|---|
| **代码常量** | `effect_runtime.h:272` `SELECTOR_MAX_CELLS = 32` | 所有选择器的硬上限 |
| **内容参数** | 194 个 program 的 `target_selector_param = (32, 0)` | 内容侧显式声明 |
| **实例截断** | `ideology_runtime.cpp:2133` `targets.resize(SELECTOR_MAX_CELLS)` | 实例路径的 32 格 |

## 2. 内容侧的实测

扫描三个效果 catalog 资源里所有 `target_selector_kind = 12`：

```
kind 12 program instances: 194
cap distribution: {'32': 194}
with tag param[1] != 0: 0
```

**194 / 194 全部是 `(32, 0)`。** 没有例外，也没有任何一个用 tag 过滤。

这意味着：**代码侧把 32 删掉，内容侧仍会在 `param0` 处截断到 32。**

## 3. 三者互相钳制，且改法有顺序约束

三条关键路径：

```cpp
// economy_runtime_family_buff.cpp:2389-2391（kind 12）
const int32_t cap = param0 > 0 ? std::min(param0, SELECTOR_MAX_CELLS)
                               : SELECTOR_MAX_CELLS;

// 同上 :2430-2431、:2477、:2495（kind 14/15/16）
```

即 **`cap = min(内容参数, 32)`**。内容写 64，仍得 32。内容写 0（表示「用默认」），也仍是 32。

更要紧的是**编译期校验会拒绝超过 32 的内容参数**：

```cpp
// effect_runtime.cpp:1005-1013
definition.target_selector_param[0] < 0 ||
(definition.target_selector_kind != SELECTOR_TAG_SOURCE_COUNT &&
    definition.target_selector_kind != SELECTOR_FAMILY_OWNED &&
    definition.target_selector_param[0] > SELECTOR_MAX_CELLS) ||
...
    return failure("effect_family_metadata_invalid");
```

**所以正确的改动顺序只能是：**

1. 先放宽 `SELECTOR_MAX_CELLS`（或改成按 selector 种类区分的上限）并同步 13 处使用；
2. 再更新 194 个内容参数；
3. 最后处理 `ideology_runtime.cpp:2133` 的实例截断（或让该路径对派生卡不生效）。

**反过来做（先改内容）会被 catalog 直接拒绝，整个 catalog 编译失败。**

## 3.1 实测：改内容确实会被拒绝

不靠阅读源码推断，我直接做了一次可回滚的最小实验：把 `default_ideology_effects.tres` 里**一个** kind-12 program 的参数从 `(32, 0)` 改成 `(64, 0)`，然后跑 catalog 编译。

结果：

```
FAIL ideology catalog compiles
  { "ok": false, "reason": "ideology_effect_selector_cap_invalid" }
```

数据已逐字节恢复（`PackedInt32Array(64, 0)` 出现次数归零，`git diff` 干净）。

**这条实验同时纠正了我的一处判断**：拒绝发生在 **GDScript 侧**（`scripts/ideology/ideology_effect_definition.gd:261-266`），不是我原先以为的 C++ `effect_runtime.cpp:1005-1013`。两层都有校验：

| 层 | 位置 | 条件 |
|---|---|---|
| GDScript | `ideology_effect_definition.gd:261-266` | kind 非 16/非 FAMILY 时 `param[0] > SELECTOR_MAX_CELLS` → `ideology_effect_selector_cap_invalid` |
| C++ | `effect_runtime.cpp:1005-1013` | 同条件 → `effect_family_metadata_invalid` |

**所以放宽上限要改两层校验，不是一个常量。**

## 4. 一处需要注意的非对称

`effect_runtime.cpp:1006-1008` 对 `SELECTOR_TAG_SOURCE_COUNT` 与 `SELECTOR_FAMILY_OWNED` **豁免**了上限检查：

```cpp
definition.target_selector_kind != SELECTOR_TAG_SOURCE_COUNT &&
definition.target_selector_kind != SELECTOR_FAMILY_OWNED &&
definition.target_selector_param[0] > SELECTOR_MAX_CELLS
```

但 `collect_effect_target_cells` 对这两个种类的 `param0` 仍然 `min(param0, SELECTOR_MAX_CELLS)`（`:2430`、`:2477`）。

**校验豁免了，运行时仍封顶。** 这意味着「内容可以写 1000」是个错觉，实际仍得 32。这大概是历史遗留，但它会让人误判 M4 的工作量——E/F 批次（kind 14/15/16）看似不受上限，实际仍受限。

## 5. 对里程碑范围的影响

| 里程碑 | 原以为 | 实际还需要 |
|---|---|---|
| M2（A/B，kind 12） | 接线派生层 | + 放宽常量 + 改 194 个内容参数 + 处理实例截断 |
| M4（E/F，kind 14/15/16） | 启用来源选择器 | + 运行时的 `min(param0, 32)` 四处 |

即 **M2 的实际工作量比方案估计的大一档**，且大部分是内容批量改动，不是代码。

## 6. 建议

1. **把 `SELECTOR_MAX_CELLS` 拆成按种类区分的上限**，而不是一个全局常量。kind 12/14/15/16 需要的是「按真实领土/来源数」，而径向扇出（NEIGHBORS_R1/R2）确实需要一个界（37/61 是它自己的几何上限）。用一个数覆盖两种语义是当前设计的核心问题。
2. **内容改动应作为独立可评审批次**，与代码常量解耦，否则一次提交同时动 194 个 `.tres` 和常量，回归归因会很难。
3. **同步更新方案 §1.1 的「取消 32 上限」定义**，明确它是三层联动的结果，不是单点删除。

## 7. 局限

- 本轮**只做了分析，未改任何代码或内容**。三类改动都会显著影响既有 15 个 fixture 的判定，需要单独一轮做并跑完整回归。
- 未统计非 kind-12 的 `SELECTOR_MAX_CELLS` 使用（`NEIGHBORS_R1/R2` 走 `:7176` 的固定 32，那是几何上限，不属于本次迁移范围）。
- 未验证放宽常量后 `effect_stable_cap` 的分布是否仍「稳定」（该函数保证截断子集不总是领土的低 id 部分，取消上限后它的作用会变）。
- 未核对 GDScript 侧的 catalog 校验是否也有 32（`effect_catalog.gd` 里未找到对应检查，但未穷尽）。

## 8. 复算方式

```powershell
# 内容侧统计（194 / 194 全为 (32, 0)）
python -c "
import pathlib, re, collections
dist = collections.Counter()
for f in pathlib.Path('Project/project-keynes/data').rglob('*.tres'):
    t = f.read_text(encoding='utf-8', errors='ignore')
    for m in re.finditer(r'target_selector_kind = 12\b', t):
        seg = t[m.start():m.start()+400]
        pm = re.search(r'target_selector_param = PackedInt32Array\(([^)]*)\)', seg)
        dist[(pm.group(1) if pm else 'none')] += 1
print(dist)
"

# 代码侧枚举
Select-String -Path gdext/src/*.cpp,gdext/src/*.h -Pattern 'SELECTOR_MAX_CELLS'
```
