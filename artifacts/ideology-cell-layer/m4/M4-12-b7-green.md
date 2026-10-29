# M4-12 B7 全绿：32 格上限在 1600 格领土上已被取消（决定性证据）

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §14.2 B7 + §12.4 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **14 checks / 0 failures**；派生 front **3200 格**；**零实例** |
| 结论 | 方案的核心承诺已被直接测量，不再是推断 |

## 1. 决定性证据

```
[B7] country-runtime owned cells = 1600
[B7] idea active = 1, locations = [1]
[B7] territory plane = { cell_count: 1600, plane_size: 1600, slot0_cell_count: 1600,
                         cell0_country: 0, anchor0: 0, plane_matches_cell_count: true,
                         own_territory_branch: 4, own_territory_owned: 6400,
                         own_territory_emitted: 6400,
                         own_tag_rejected: 0, own_pushed_raw: 6400 }
[B7] materialise seen=1600 derived=1600 legacy=0
[B7] STAGES entries=4 templates=8 program_empty=0 pod_fail=4 targets_fail=0 emitted=6400
[B7] derived front cells = 3200, stat_count = 2
[B7] effect instances = 0
=== B7 wide territory: 14 checks, 0 failures ===
```

### 三个数字各自证明了什么

| 数字 | 含义 |
|---|---|
| **`front cells = 3200`** | **取消 32 上限**：旧上限是每卡 32 格，这里是 3200 格（2 个 stat × 1600 cell）|
| **`instances = 0`** | **I01 达成**：派生卡不创建任何 Effect 实例 |
| **`derived = 1600, legacy = 0`** | 该国的 1600 格全部由派生层承载，无一退回实例路径 |

**`3200 >> 32`，这是「32 格限制已取消」最直接的测量。**

## 2. 打通的完整链路（12 步）

| 步 | 结果 |
|---|---|
| `create_entities(1600)` | 槽位按 1600 分配 |
| 10 个环境槽注册并清零 | 捕获前置满足 |
| `configure_economy / effects / modifiers / country` | 全部 ok |
| `bootstrap_country`（1600 格领土） | `owned cells = 1600` |
| `configure_ideologies` | ok（**需保留原 tag 列表**）|
| `begin_or_reuse_economy_input_epoch`（6 字段） | ok |
| `bootstrap_economy` | ok |
| `run_economy_slice` × 48 | `done=true` |
| GRANT → DISCOVER → understanding → EQUIP | `locations=[1]` |
| `run_ideology_daily` × 10 | ACTIVE |
| 目标解析 | `targets_fail = 0` |
| 物化 | `derived=1600` |

## 3. `seen=0` 的最终根因（六轮后才查清）

**所有 kind-12 卡都带 tag 过滤器，而 tag 谓词需要真实经济状态。**

| 轮次 | 当时的判断 | 真相 |
|---|---|---|
| M3-12 | rollout 关闭 | 已开 |
| M3-13 | 需要采纳卡 | 已采纳，tag 不匹配 |
| M3-21 | 理念未激活 | 已激活，tag 仍不匹配 |
| M3-22 | anchor 无效 | `anchor=0` 有效 |
| M4-9 | 采集器某处退出 | 所有前置通过，`own_tag_rejected=6400` |
| **M4-12** | — | **tag 谓词为假** |

**决定性数据是 `own_tag_rejected = 6400`**（4 程序 × 1600 格全部被 tag 拒绝）。

## 4. 修复的关键三步（都是我的诊断错误）

### 4.1 tag 必须设置在 Resource 上，编译之前

```gdscript
# 错：写编译产物
effect_ir["target_tags"] = tags      # 无效或崩溃（exit -1）

# 对：写 Resource，再编译
_install_satisfiable_tag(domain)
var effect_ir: Dictionary = domain.compile_native_catalog()
```

`target_tags` 是 `compile_native_catalog` 的**输入**，不是输出。

### 4.2 必须是 `Array[Dictionary]` 类型化数组

```
SCRIPT ERROR: Invalid assignment of property 'target_tags'
              with value of type 'Array' on a base object of type 'Resource (EffectCatalog)'
```

`@export var target_tags: Array[Dictionary]`——赋未类型化的 `[{...}]` 静默失败。

### 4.3 必须保留原有 tag 列表，只替换目标项

整体覆盖导致：

```
FAIL ideologies configure ideology_synergy_override_tag_unknown
```

理念目录声明了引用**其他** tag 的 synergy override。只替换 `cell.settlement`、保留其余，问题消失。

## 5. 性能数据（顺带取得）

| 指标 | 值 |
|---|---|
| `cell_layer_rebuild_ms` | **2.693 ms**（1600 格）|
| `tag_snapshot_build_ms` | **16.61 ms**（1600 格，2 次构建）|
| 经济日 0 | 48 slices |

对照 48 格场景的 `tag_snapshot_build_ms = 0.0092 ms`：**tag 重建对格数是超线性的**（33× 格数 → 1800× 时间）。这为 M4 的「per-tag changed words」提供了真实依据。

## 6. 验证

| 项 | 值 |
|---|---|
| B7 | **14 / 0** |
| 构建 | exit 0 |
| `derived_layer_rebuild_test` | 49 / 0 |
| 覆盖率门禁 | 6 / 6 |
| `x1b` / `tag_snapshot` | 142/0、38/0 |

## 7. 局限

- 单一国家、单一 tag；**未验证 100+ 来源与 r=1–4 的重叠场景**（M4 退出条件的剩余部分）。
- `pod_fail = 4` 是 4 个 cost 类程序（非 cell domain），属正确排除。
- 性能是单点测量，未做分位数。
