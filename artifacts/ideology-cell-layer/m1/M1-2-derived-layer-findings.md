# M1-2 derived layer container & ADR02 proof — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §15.3 / ADR01–ADR02 / §8.1–§8.4 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `gdext/src/derived_cell_layer.h`、`gdext/tests/derived_cell_layer_test.cpp`、`ModifierRuntime::install_derived_cell_layer` / `derived_cell_stat_version`、`tests/ideology/ideology_cell_layer_adr02_test.gd` |
| 证据 | 纯核 **51 checks 0 failures**；执行验证 **19 checks 0 failures**；构建成功；旧 DLL → 新 DLL |
| 结论 | **ADR02 从源码推断升级为执行证据**；两个真实缺陷由测试抓出 |

## 1. 交付内容

### 1.1 `derived_cell_layer.h`（ADR02 的落点）

方案 ADR02 要求派生层**不进** `ModifierRuntime::Store`，因为 `apply_pod_snapshot` 会：

```cpp
modifier_runtime.cpp:459   std::array<Store, DOMAIN_COUNT> next_stores{};   // 全新构建
modifier_runtime.cpp:557   _stores = std::move(next_stores);                // 整体替换
modifier_runtime.cpp:558   _pending_commands.clear();                       // 清空 legacy 队列
```

存储选型按 M0-7 的决定：**`stat -> 有序 cells[] + 并行 contribution[]`**，不是平铺 `(stat, cell)` 哈希。理由有二：

- reader 的模式是「给定格，问 156 个 stat」（`economy_runtime.cpp:7085-7095`）；
- `collect_scope_ids` 要回答「这个 stat 有哪些格」，在哈希上必须全键扫描——那正是方案 §14.1 表格禁止的成本。

### 1.2 ModifierRuntime 接口

```cpp
bool install_derived_cell_layer(DerivedCellFront front,
                                uint64_t expected_generation,
                                bool &skipped, std::string &error);
const DerivedCellFront *derived_cell_front() const;
uint64_t derived_cell_layer_generation() const;
uint64_t derived_cell_stat_version(const int32_t *stat_ids, size_t stat_count) const;
```

`install` 做了四件方案明确要求的事：

| 要求 | 实现 |
|---|---|
| §9.6 候选身份过期则拒绝 | `expected_generation != 0 && != 当前` → `derived_cell_layer_stale_generation` |
| §9.6 世界/地图不一致则拒绝 | `world_identity` / `map_generation` 必须匹配 |
| I13 相同输入幂等 no-op | `content_digest()` 相等 → `skipped=true`，不 bump generation |
| §17 合法空结果清除旧贡献 | 空候选 + 非空当前 → 清空并 bump |

`derived_cell_stat_version` 与 `stat_bucket_version` **分离**：`apply_pod_snapshot` 无条件 `++structure_epoch`（`:463-464`），若共用版本号，每天的空闲都会被误判为内容变化（§7.4）。

### 1.3 执行验证（M0-4 结转项）

`tests/ideology/ideology_cell_layer_adr02_test.gd` —— **19 checks, 0 failures**：

| 断言 | 结果 |
|---|---|
| 安装前 layer 为空 | pass |
| front 安装成功且 generation > 0 | pass |
| layer 携带 4 格 / 1 stat / sample_day | pass |
| **`clear_modifier_domain(ECONOMY)` 后 layer 仍 installed** | **pass（ADR02 核心）** |
| 重建后格数不变 | pass |
| 重建后 layer generation 不变 | pass |
| I13 相同内容重复安装不 bump | pass |
| §9.6 过期 generation 被拒且理由正确 | pass |
| §9.6 外部 world identity 被拒且理由正确 | pass |
| 被拒候选不影响在用 front | pass |

**这条把 ADR02 从「源码推断」升级为「执行证据」。** M0-4 只能从 `:459-557` 的代码结构推断，无法触发该路径（需 ACTIVE worker + 已提交语义日）。

## 2. 两个由测试抓出的真实缺陷

### 2.1 `reset()` 未清 `_index`

`DerivedCellFrontBuilder::reset` 清了 `_front` 却留下 `_index`（stat → 行位置）。下一个候选的 `_row()` 会拿旧位置索引空 vector，**整个候选静默丢失内容**。

`test_reset_discards_candidate` 一次抓出 3 个失败。修复：`reset` 里 `_index.clear()`。

**这类缺陷如果进了生产，表现会是「候选人有时装成功有时不装」，且只在第二次物化时出现**——极难复现。

### 2.2 空候选误关 builder

`install()` 在 `!_dirty` 时把 `_open` 设为 `false`。后果：一个合法地物化出零行的候选（空 selector 命中是 §17 允许的）之后再调用 `add()` 会被静默拒绝。

修复：空候选 `install` 只返回 `false`，**不关闭 builder**。

### 2.3 I13 幂等（由集成测试抓出）

`ideology_cell_layer_adr02_test.gd` 首跑 **19 checks, 1 failure**：相同内容重复安装把 generation 从 1 推到 2。

这与 §7.4「空闲日 layer_stat_version_bumps 增量为 0」直接冲突——一个什么都没变的世界会每天 bump 一次，所有依赖该版本的缓存全部重建。

修复：新增 `DerivedCellFront::content_digest()`（只含 stat/cell/add/factor/zero_count，**不含 generation 与 sample_day**），`install` 比对后 `skipped=true` 且不 bump。

**这个缺陷只有跑真实安装序列才会暴露**，纯核单测测不出来（它需要「先装一次、再装同样的一次」这个跨调用状态）。

## 3. 构建与回归

| 项 | 值 |
|---|---|
| 构建输出 | `Compiling shared src\world_ext_modifier.cpp` → `Linking` → `scons: done building targets.` |
| 退出码 | 0 |
| 一次编译错误 | `get_derived_cell_layer_report()` 声明缺 `const`，与实现不匹配 → 已修 |
| DLL SHA-256 | 见 §5 表格 |

## 4. 有意保留的 M1 范围线

`DerivedCellFrontBuilder::add` 会把**不同来源国**的贡献折进同一个 slot，只记录最后一个 `source_country`。

这是**刻意的 M1 边界，不是缺陷**，但它必须写清楚：

- 方案 §8.1 要求「按来源国家保留贡献，才能正确卸卡、领土变更和撤销跨国外溢」；
- 真正的逐来源撤销需要 `(stat, cell) -> {source -> contribution}` 二级结构，以及 §8.2 第 2 步的「按规范顺序重算 touched keys」。

M1 只交付**容器与安装/查询**，不含撤销。**M2 的替换路径必须替换这个折叠**，否则多国影响同一格时会算错——我已把它登记为 M2 的前置条件。

## 5. 局限

- **`install_derived_cell_layer` 尚无生产调用方。** 目前只有 test bridge 会调用它。方案 §4.2 规定调用者只能是 Economy 冻结协调器，接线属 M1 后续任务。
- **未接线到 `effective_value`。** 派生贡献还没有参与最终公式合并（§5.1 的第 4 个 add/factor）。这是本里程碑最重要的一项，也最危险——一旦接错，所有 stat 都会算错。
- **未实现 `collect_scope_ids` 并集**、read view、explain unclamped。
- `content_digest()` 把 double 转成 `×1e6` 的整数再哈希，**精度只到 1e-6**。两个相差小于 1e-6 的 ADD 会被视为相同内容。对 Q16 量级（1/65536 ≈ 1.5e-5）足够，但如果将来引入更大的动态范围，这个粒度需要收紧。
- 未测峰值内存与分配次数。

## 6. 复算方式

```powershell
# 纯核
cd gdext
cl /nologo /std:c++17 /EHsc /W4 /I src tests\derived_cell_layer_test.cpp `
   /Fe:..\.codex-tmp\derived_layer_test.exe /Fo:..\.codex-tmp\
& ..\.codex-tmp\derived_layer_test.exe     # => 51 checks, 0 failures

# ADR02 执行验证
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_adr02_test.gd' `
  -RedirectStandardOutput artifacts/ideology-cell-layer/adr02.log `
  -RedirectStandardError  artifacts/ideology-cell-layer/adr02.err.log
# => 19 checks, 0 failures
```
