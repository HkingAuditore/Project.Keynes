# M5-5 「周围地块」归属筛选：默认 OWN，支持 FOREIGN / ANY

| 项目 | 内容 |
|---|---|
| 里程碑 | 新增目标项（用户指定）|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **kind 14/15/16 的扇出加归属过滤，默认 OWN**；内核 **85 / 0**；全回归 **19 / 19** |
| 影响面 | 71 个程序（5× kind 14 + 66× kind 16）|

## 1. 问题

「周围地块」的扇出**没有归属概念**：

```cpp
// economy_runtime_family_buff.cpp:2646-2664
for (depth...) for (cell : frontier) for (dir = 0..5) {
    neighbor = _building_neighbors[cell * 6 + dir];
    if (!accepts(neighbor)) continue;   // 只查 地形 / 资源 / 谓词
    out_cells.push_back(neighbor);
}
```

**在该函数体内 grep `cell_country_slot` / `_epoch_cell_country`：零命中。**

所以一张写成「周围 1 格工业 +10%」的卡会跨过国界作用到邻国地块上。

## 2. 实现

### 2.1 新头文件 `selector_ownership.h`（Godot-free）

按 `selector_cell_cap.h` 的先例抽出：纯整数逻辑，必须能脱离 godot_cpp 单测。
**这不是装饰**——把它留在 `effect_runtime.h` 里正是让「默认值写错」无法被测出来的原因。

```cpp
enum OwnershipScope : int32_t {
    OWNERSHIP_OWN = 0,      // 只本国 —— 默认
    OWNERSHIP_FOREIGN = 1,  // 只他国
    OWNERSHIP_ANY = 2,      // 不过滤（改动前行为）
};
inline constexpr int32_t OWNERSHIP_SCOPE_SHIFT = 12;
```

**存储位置**：`target_selector_param[0]` 的 bit 12..13，**14/15/16 三个 kind 统一**。
理由：kind 16 已占用 0..11，14/15 只用 0..4，12..13 是三者共同的首个空闲位置。

**未知值（3）回退到 `ANY` 而不是 `OWN`**：静默收窄一张意图不明的卡，会让它的目标集凭空消失——而空目标集和「这张卡没匹配到东西」无法区分。

### 2.2 两条路径的过滤

| kind | 位置 | 方式 |
|---|---|---|
| 14 / 15 | `ideology_runtime.cpp` 扇出循环 | 逐 source 取 `cell_country_slot(source)`，过滤 `ring` |
| 16 | `ideology_runtime.cpp` 出口循环 | 逐 cell 比 `cell_country_slot(cell) == country_slot` |

**为什么在 IDEOLOGY 侧过滤而不是改 economy 的 selector API**：`ring` 受 `ring_cap ≤ 32` 约束，一次查表比改一个被多处依赖的 selector 接口风险低得多。

## 3. 途中修掉的两个我引入的缺陷

### 3.1 `collect_own_tagged_cells(-1)` 返回空

第一版用 `collect_own_tagged_cells(country_slot, -1, own_tagged)` 取「全国领土」。

```cpp
// economy_runtime_family_buff.cpp:1010
if (country_slot < 0 || tag < 0 || tag >= _target_tags.count()) return;
```

**`tag < 0` 直接返回空**，于是「这格是我的吗」对每一格都是 false，**OWN 模式会把目标集清空**。

改为直接 `cell_country_slot(cell) == country_slot`。

### 3.2 `param0` 的 cap 没有屏蔽归属位

kind 14/15 原本 `cap = min(param0, 32)`。加了 bit 12 之后，`param0 = 4096 + 32`：

- `4096 > 0` 让三元判断为真 → `min(4096, 32) = 32`，**看起来正确**
- 但作者写 `cap = 0`（意为「默认」）时，`param0 = 4096` 也判为真 → 哨兵值失效

已加 `OWNERSHIP_CAP_MASK` 显式屏蔽，内核测试固定了这一点。

## 4. 内容侧兼容性验证

74 个 kind 14/16 卡的实际 `param0` 值：

```
kind 14: 32              → 32  >> 12 = 0 → OWN
kind 16: 544/576/800/832/864/1568 → 全部 >> 12 = 0 → OWN
```

**没有一张卡显式写过归属位，因此全部落到新的 OWN 默认。** 这正是用户要求的语义变更。

**编译期安全性已核实**：`_write_selector_tag_id`（`effect_domain_catalog.gd:735-742`）只写 `params[1]`，`params[0]` 原样保留，所以解析 tag 名不会冲掉归属位。

## 5. 验证

### 5.1 内核（确定性，85 checks / 0 failures）

| 断言 | 意义 |
|---|---|
| `an unauthored scope defaults to OWN` | **默认值** |
| `a live kind-16 param decodes as OWN`（6 个真实值）| 74 张卡不会悄悄保持旧行为 |
| `OWN / FOREIGN / ANY round-trips` | 显式取值 |
| `an unknown scope falls back to ANY` | 不静默清空 |
| `masking the scope leaves cap 0 intact` | 哨兵值缺陷 |
| `OWN + FOREIGN partition ANY`（20 个混合样本）| **两种范围恰好划分全集** |

### 5.2 全回归 19 / 19

含 B7（1600 格）、B8（144 来源）、B10（两国）、x1b（kind 16，142 检查）、tag 翻转压力。

**单国世界里 OWN 与 ANY 等价**，所以这些 fixture 通过是预期结果——它证明改动没有误伤，但**不证明边境行为正确**。

## 6. 未验证的部分（重要）

**跨境的 OWN / FOREIGN 差异没有端到端证据。**

我写过一个双国 kind-16 测试，但 `_equip_and_measure` 从未真正把归属位写进卡里——它只是把参数传了一遍。**那个测试是假的，我删掉了**，没有留一个「通过」的假象。

要补的话，需要一个能重写编译后目录里某张卡 `target_selector_param[0]` 的夹具（在 `compile_native_catalog` 之前改 Resource）。

**当前能确证的**：默认值、解码、过滤谓词、划分性质（全部内核级，确定性）；
**当前不能确证的**：一张真实卡在真实双国边境上的目标集差异。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `gdext/src/selector_ownership.h` | **新增**，Godot-free 的归属语义 |
| `gdext/src/effect_runtime.h` | 改为委托该头文件 |
| `gdext/src/ideology_runtime.cpp` | 14/15 扇出过滤 + 16 出口过滤 + cap 屏蔽 + 3 个计数器 |
| `gdext/src/ideology_runtime.h` | 计数器字段 |
| `ideology_effect_definition.gd` | `pack/unpack_source_count` 带 ownership，默认 OWN |
| `gdext/tests/derived_layer_rebuild_test.cpp` | 67 → **85 checks** |

## 8. 局限

- 跨境差异未端到端验证。
- 未量化改造对 74 张卡的数值影响（多少格被过滤掉）。
- `ownership_filtered_resolves` / `_own_resolves` / `_foreign_resolves` 三个计数器已导出，但尚未观察到非零值。
- 内容侧未改：74 张卡仍显式写 `param0`，只是解码后落到 OWN。若要某张卡恢复旧行为需显式设 `ANY`。
