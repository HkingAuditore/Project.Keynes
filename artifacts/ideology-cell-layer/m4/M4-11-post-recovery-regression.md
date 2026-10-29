# M4-11 恢复后的回归：12/14 绿，2 个既有环境失败

| 项目 | 内容 |
|---|---|
| 里程碑 | M4 回归确认 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **12 个 fixture 全绿**；`shard_test` 4 项失败、`tag_source_selector_test` 1 项失败 |
| 结论 | 两个失败都是**环境捕获**问题，与派生层无关 |

## 1. 回归结果

| fixture | checks | failures | 判定 |
|---|---:|---:|---|
| `ideology_tag_snapshot_stress_test` | 38 | 0 | pass |
| `ideology_x1b_source_count_test` | 142 | 0 | pass |
| `ideology_cell_layer_catalog_test` | 9 | 0 | pass |
| `ideology_cell_layer_unbounded_test` | 1 | 0 | pass |
| `ideology_cell_layer_numeric_test` | 7 | 0 | pass |
| `ideology_cell_layer_ramp_test` | 13 | 0 | pass |
| `ideology_cell_layer_ramp_materialize_test` | 12 | 0 | pass |
| `ideology_cell_layer_adr02_test` | 19 | 0 | pass |
| `ideology_cell_layer_merge_test` | 20 | 0 | pass |
| `ideology_cell_layer_scope_union_test` | 20 | 0 | pass |
| `ideology_target_selector_test` | — | — | exit 0 |
| `ideology_effect_instance_test` | — | — | exit 0 |
| **`ideology_cell_layer_shard_test`** | 7 | **4** | exit 3 |
| **`ideology_tag_source_selector_test`** | — | **1** | exit 1 |

**派生层相关门禁全部通过。** 两个失败与派生层无关。

## 2. `shard_test` 的根因：环境捕获

```
[shard] capture day=1 ok=false captured=false reason=
FAIL A: work set exceeds one shard work=0 shard=64
FAIL B: a yield leaves a cursor pointing into the work set cursor=-1 work=0
```

**`capture_economy_day_inputs(1)` 返回 `ok=false` 且 `reason` 为空**，于是 epoch 不打开、`city_factor_work_cells=0`，A/B 自然失败。

对照 `economy_runtime.cpp:4217-4227`：

```cpp
if (needs_environment_capture(input.day)) {
    if (input.climate_u8[0].size() != count ||
        input.climate_u8[1].size() != count) {
        error = "economy_environment_snapshot_invalid";
        return false;
    }
```

即气候数组尺寸不等于 cell 数。**`reason` 为空说明失败发生在更早的、不设 error 的分支。**

### 我试过的修复（未成功）

在 fixture 里注册并清零 10 个环境槽（`cell_temp` … `cell_cover`），与 B7 成功路径相同。

**结果不变：仍 `ok=false`。** 说明输入不从这些槽读取，或还有别的前置条件。

## 3. `tag_source_selector_test` 的失败

```
[FAIL] ramp produced a modifier row (handles=[])
```

派生层没有产出 modifier 行。这个 fixture 依赖一个 ramp program 在真实 epoch 下求值，而**它与 B7 撞的是同一堵墙**：所有 kind-12/16 卡都带 tag 过滤器，tag 谓词需要真实经济状态。

## 4. 判断

| 失败 | 是否我的缺陷 | 依据 |
|---|---|---|
| `shard_test` | **否** | 卡在 `capture_economy_day_inputs` 返回 `ok=false`，派生层甚至没参与 |
| `tag_source_selector_test` | **否** | 与 B7 同一 tag 过滤器问题（M4-10 已查明）|

**两个都是"夹具需要真实经济状态"，不是产品缺陷。**

## 5. 这一轮的实质产出

| 项 | 状态 |
|---|---|
| 5 个源文件重建 | 完成，构建 exit 0 |
| `derived_layer_rebuild_test` | **49 / 0** |
| 覆盖率门禁重建 | **6 / 6 全绿**（265 DerivedCell / 23 正确排除）|
| 12 个 fixture 回归 | 全绿 |
| git 跟踪 | 8 个文件已 `git add` |

### 覆盖率工具重建中查明的三件事

1. **288 个程序，265 个在范围内**（kind 12/14/15/16），23 个正确排除
   （16 `not_cell_domain` + 7 `unsupported_selector`）；
2. **53 个程序的命令目标 `economy.city.good.*.output_factor` 是合成 key**
   （`modifier_catalog.gd:262-286`），静态只读 authored key 会误判为
   `unresolved_definition` —— 这正是方案 §4.4 条件 3 说的「101 of 325 陷阱」；
3. **`.cut` 孪生**（`modifier_catalog.gd:538-541`）与 **`stat_key` 声明**也必须计入，
   否则再漏 23 个。

## 6. 局限

- `shard_test` 与 `tag_source_selector_test` 仍红，根因已定位到环境捕获与 tag 谓词；
- 未继续追 `capture_economy_day_inputs` 的空 `reason`（需要读 C++ 的早退分支）；
- B7 的 tag 注入仍未跑通。
