# M2-10 realworld loaded reading — and why it is not the number we wanted

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §14.4 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | 修正 harness 档位顺序；取得 `work_cells=2000` 的真实读数 |
| 结果 | **`city=0.003 ms` 是版本早退的耗时，不是 2000 格的成本** |
| 结论 | 本轮推翻了上一轮的一个隐含假设，且找到了它为什么不成立 |

## 1. 上一轮的问题：档位顺序

`_sample_epochs` 每次消耗 `EPOCH_SAMPLES + 1` = 7 天。原顺序是 `idle → loaded A → loaded B`，共 21 天，而经济在 **day 4** 就致命。所以 loaded 档永远在死亡之后才开始采样。

改成 **loaded 优先**后立刻拿到数据：

```
loaded A (2000 cells)  n=2  min=0.002  p50=0.002  max=0.002 ms
work_cells=2000  cursor=-1  good_count=134
```

这是本轮的真实进展：**harness 现在能测到 loaded 档了**。

## 2. 但这个数字不可能是 2000 格的成本

乘数确认无误（`good_count=134`，模型推算 156 = 2 + 20 need + 134 good）。那么：

```
2000 格 × 156 stat = 312,000 次查询，耗时 0.003 ms
=> 每次查询约 10 皮秒
```

现代 CPU 一次哈希查找约 5-20 纳秒，**差了三个数量级**。这不可能是真的。

## 3. 真正的原因：`cursor=-1` 有两种含义

`refresh_city_modifier_factors` 有两条路径会走到 `cursor = -1`：

```cpp
// (a) 版本早退：没有任何工作要做
if (_city_factor_shard_cursor < 0 && _epoch_city_factor_valid &&
    shape_valid && _epoch_city_factor_stat_version == version) {
    return true;                       // ← 没有进入格子循环
}
// (b) 分片跑完
_city_factor_shard_cursor = -1;
```

`work_cells=2000` 只在 **collect 分支**被写入：

```cpp
if (_city_factor_shard_cursor < 0 || _city_factor_shard_version != version) {
    collect_scope_ids(...);
    _city_factor_work_cells = ...;      // ← 只在这里更新
}
```

所以第 1 天收集到 2000 格、记下 `work_cells=2000`；从第 2 天起版本未变，**走 (a) 早退**，`work_cells` 保持旧值 2000，`cursor` 保持 -1。

**0.003 ms 是早退的耗时。** 我测的是「没有工作可做」的时间，不是「2000 格的工作」的时间。

## 4. 这暴露了一个诊断字段的缺陷

`city_factor_work_cells` 名为「工作集大小」，但它只反映**最后一次 collect 的结果**，与「本 slice 实际处理了多少格」无关。一个读者完全跳过工作集时，它仍显示 2000。

这正是我在 M1-6 引入这个字段时想解决的问题（「无法区分跑了但没找到 / 压根没跑」），但它只解决了一半：

| 问题 | 是否解决 |
|---|---|
| collect 是否执行过 | ✅ `work_cells` 在 collect 分支更新 |
| **本 slice 是否真的处理了格子** | ❌ **无法区分早退与完成** |

**正确做法**：需要一个「本 slice 实际处理的格数」计数器，在格子循环里自增。这样早退时它保持 0，跑完时它等于工作量。

## 5. 为什么这个问题值得单独立项

它不是一个笔误，而是**「快读数被误当作便宜证据」**的典型：

- 若我停在第 2 节，会报告「2000 格只需 0.003 ms，比模型快 4000 倍」，并据此宣布性能问题不存在；
- 实际结论是**根本没有测到那个工作量**。

方案的 §14.4 恰好警告过这一点（引用 §7 的 harness 自述）：

> 同一覆盖率跑两组，若 `loaded == idle` 就打印 `NOT RESOLVED`……而不是输出一个自信的 0.003 ms。

harness 有 `NOT RESOLVED` 检查，但它比较的是 idle 与 loaded 的**时间**。当两者都因早退而接近 0 时，`is_equal_approx` 会判定相等并触发警告 —— 本轮确实触发了（`idle==loaded`），但 loaded 档本身已经先因 fatal 失效，警告被淹没在 `INCOMPLETE` 里。

## 5.1 加计数器后得到的确证

新增 `_city_factor_cells_processed`（在格子循环内自增），重跑：

```
work_cells=2000  processed=16  cursor=-1  city=0.142 ms   (warmup)
work_cells=2000  processed=16  cursor=-1  city=0.002 ms   (稳态)
```

**`processed=16` 而不是 2000。** 这比上一节的推断更精确，说明：

1. `work_cells=2000` 是**第一次 collect** 的结果，之后一直被复用（版本未变）；
2. 每次 `refresh_city_modifier_factors` 只处理 **16 格**就返回；
3. `cursor=-1` 出现在**下一轮**调用里，而那一轮因为版本已变而重新开始。

机制链条：

```
collect → work_cells=2000, cursor=0
loop 处理 16 格 → 版本变化被检测到 → 本片放弃，cursor 归位
下一轮 → 版本不同 → 重新 collect → 又只处理少量
```

所以 `city=0.002 ms` 对应的是 **16 格的成本**，不是 2000 格。按 6.0 us/格估算，16 格理论上约 0.096 ms，实测 0.002 ms 仍偏低，说明这 16 格大多没有 group 桶（`if (scope_id < cells)` 之外的路径不计入 `processed`）。

**无论如何，它离「2000 格的真实成本」还很远，不能用来验收 §14.3。**

## 6. 下一步（明确）

1. **加 `city_factor_cells_processed` 计数器**，在格子循环内自增，报告时清零。有了它，「早退」与「完成」才可区分。
2. 用它重测：若某一天 `cells_processed == 2000`，那次 `city=` 才是真实成本。
3. 由于版本 gate 会让后续天早退，**只有版本变化的那一天**才有真实工作量。这意味着：

   - 要么每天改动一次 modifier 版本（注入新行）以强制真实工作；
   - 要么接受「首次收集那天」的读数，并在报告里标明它对应的是「冷建」而非「稳态热更新」。

   §14.1 本来就区分冷建与热更新，所以第 2 条是合法答案，但必须写清楚。

## 7. 局限

- 本轮**没有取得可用的 loaded 成本**。
- `idle` 与 `loaded B` 仍因 day-4 既有缺陷无法采样（`INCOMPLETE`）。
- 新加的 `counts:` 诊断确认 `good_count=134`，这是有用的副产物：证明了 156 这个乘数在真实世界里成立。
- 未验证 `need_count`（报告里没有该字段，返回 `n/a`）。

## 8. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_m0_realworld_cost_test.gd'
# => loaded A 取得 work_cells=2000，但 city=0.003 ms（早退，非成本）
```

关键代码位置：

| 结论 | 位置 |
|---|---|
| 版本早退不进入格子循环 | `economy_runtime.cpp:7035-7038` |
| `work_cells` 只在 collect 分支更新 | `economy_runtime.cpp:7118-7119` |
| `cursor=-1` 有两条路径 | 同上两处 |
