# M1-13 target resolution root cause — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §6.1 / §13.1 第 4 层 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结论 | `targets_ok=0` 的真实根因是 **`_epoch_cell_country` 只在 epoch 打开时填充**，不是 tag 问题 |
| 状态 | e2e 仍 19 checks 0 failures（`Off` 分支）；ON 分支被同一前置挡住 |

## 1. 我上一轮的推断是错的

M1-12 我写下：「`cell.clan` 需要 tag，而内容未声明该 tag」。

本轮实测推翻了这个结论：

```
[e2e] tag override accepted=64 of 64  first_failure={ }
```

**override 全部被接受。** 按 `set_cell_tag_override_for_test` 的实现（`economy_runtime_family_buff.cpp:2070`），只有在 `_target_tags` 里找不到该 tag 时才会返回 false。既然 64/64 都成功，说明**表里确实有 `cell.clan`**。

继续追查也确认 tag 表不是从 `.tres` 直接读的，而是 `effect_domain_catalog.gd:500` 的 `catalog.target_tags = tag_list` **合成**出来的——所以「三个 .tres 都没有 `target_tags` 字段」这件事并不代表表是空的。我上一轮把这两件事混为一谈了。

## 2. 真正的根因

`collect_effect_target_cells` 的 kind 12 分支（`economy_runtime_family_buff.cpp:2368-2417`）：

```cpp
const int32_t tag = param1 > 0 ? param1 - 1 : -1;   // (32, 0) -> tag = -1，不过滤 tag
...
const int32_t country = cell_country_slot(source_cell);
if (country < 0) { out_cells.push_back(source_cell); return; }   // 单格退化
const int32_t owned = country_cell_count(country);               // 0 -> 空
for (int32_t index = 0; index < owned; ++index) { ... }          // 循环一次都不走
```

而：

```cpp
int32_t NativeEconomyRuntime::cell_country_slot(int32_t cell) const {
    if (_epoch_cell_country.size() != static_cast<size_t>(_cell_count.get()))
        return -1;                                                // ← 这里返回 -1
    ...
}
```

`_epoch_cell_country` 的唯一生产填充点是 `apply_pod_snapshot` 路径：

```cpp
// economy_runtime.cpp:4986
_epoch_cell_country = std::move(snapshot.cell_country_slot);
```

它由 `capture_country_epoch` 里的 `_country_runtime->copy_economy_snapshot()` 提供，**只在经济 epoch 打开时发生**。

`target_selector_param = (32, 0)` 里 `param1 == 0`，所以 `tag = -1`，**tag 过滤根本没参与**。上一轮把注意力放在 tag 上是完全跑偏的。

## 3. 这条约束对本迁移的意义

这是本迁移的**第三条硬前置**，且前两条已被记录：

| 前置 | 说明 | 记录位置 |
|---|---|---|
| 1 | 派生层由理念运行时拥有，不需要 economy epoch | M1-11 |
| 2 | 但**目标解析**需要领土索引，而它需要 epoch | **本轮** |
| 3 | 分片与物化的真实执行证据需要 worker 协作夹具 | M1-8 |

三者合起来说明一件事：**`cell` 域（kind 12/14/15/16）的派生路径无法脱离经济 epoch 端到端验证**，因为目标格集来自领土 CSR。

反过来说，这也是一个设计观察：`resolve_effect_targets` 里 kind 12 依赖 `_epoch_cell_country`，而 `_epoch_cell_country` 是 epoch 级快照。所以**派生层的第一批（M2，A/B 全为 kind 12）天然要求「epoch 已打开」**，这与 §4.2 把安装点放在 Economy 冻结协调器是一致的——只是我之前一直试图在没有 epoch 的世界里验证它。

## 4. 一处内容注释与实际不符

`economy_runtime_family_buff.cpp:2372-2373` 写：

> those were placeholders for exactly this, and **nothing in content uses kind 12 yet**

但 M1-1 的覆盖率统计显示 **170 个 program 用 kind 12**。这条注释已过期，建议随 M2 更新，避免下一个人按它推断「kind 12 没人用，可以随便改」。

## 5. 本轮验证到的正面结果

| 项 | 结果 |
|---|---|
| tag override 可安装 | 64/64 接受 |
| tag 表非空 | 由 override 接受反推 |
| `param1 == 0` 时不参与 tag 过滤 | 源码 `param1 > 0 ? param1 - 1 : -1` |
| e2e | **19 checks, 0 failures** |
| 全部纯核门禁 | materializer 65 / eligibility 56 / shard 56 / layer 51 |

## 6. 局限

- **仍然没有 ON 分支的证据。** 本轮只是把「为什么不能」从「tag 未声明」纠正为「领土索引需要 epoch」。结论更准确，但能力没有前移。
- 未测「用 C++ 直接注入 `_epoch_cell_country`」的路径——那会绕过生产填充逻辑，得到的证据强度与既有 `economy_runtime_effect_selector_tests.cpp:163` 同级（单测级，不是端到端）。
- 未验证 tag 表里 `cell.clan` 的实际索引与行内容。

## 7. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_e2e_test.gd'
# => 19 checks, 0 failures; tag override accepted=64 of 64

# 根因核对（无需运行）：
#   economy_runtime_family_buff.cpp:2374   param1 -> tag 映射
#   economy_runtime_family_buff.cpp:2382-2392  country slot / owned
#   economy_runtime_family_buff.cpp:2367   cell_country_slot 的 size 守卫
#   economy_runtime.cpp:4986               _epoch_cell_country 的唯一生产填充
```
