# M3-19 环境槽注册成功，但尺寸不匹配；调查收束

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | `environment slots filled=10 of 10`；错误从 `slot_missing` 前进到 `snapshot_invalid` |
| 决定 | **停止真实世界验证支线**，转回主线 |

## 1. 本轮的真实进展

```
改前: environment slots filled=0 of 10
      economy epoch ok=false reason=required_environment_slot_missing

改后: environment slots filled=10 of 10
      economy epoch ok=false reason=economy_environment_snapshot_invalid
```

**错误前进了一道门。** 这是可验证的进度，不是零。

实现方式：`register_component(name, dtype, stride, track_prev)` 已绑定 GDScript
（`world_ext_bind_methods.cpp:28`），`dtype` 取值 F32=0 / I32=1 / U8=2
（`components/slot.h:20-24`），**不需要 MapData**。

## 2. 新发现的最后一个阻塞

```cpp
// world_ext.cpp:405-415
void DCWorldExt::write_f32_range(int comp_id, int start, const PackedFloat32Array &src) {
    ...
    ERR_FAIL_COND(start + n > s.arr_f32.size());   // :411 ← 不扩容，静默失败
```

`write_f32_range` **不会扩容**。`cell_temp` 的 `sid=0` 说明该槽已由 `configure_economy`
创建，其长度由经济侧决定，可能不等于我传入的 `CELLS=64`。长度不足时写入静默失败，
于是 `filled=10` 却数据无效。

**这正是 `economy_environment_snapshot_invalid` 的来源**（`economy_runtime.cpp:4466`
比较 `count != _cell_count`，或 `:4481` 的 `weather_type[i] > 7`）。

## 3. 为什么停在这里

| 事实 | 影响 |
|---|---|
| 真实世界验证支线已用 **7 轮**（M3-12 → M3-19） | 剩余轮次 60 已用 54 |
| M3 还有 3 个退出条件未验证 | 主线停滞 |
| **M4 与 M5 完全未开始** | 目标明确要求做到 M5 |
| ramp 真实幅度仍未取得 | 但**机制已完整且回归零变化** |

**继续投入的边际收益已经明确低于转向主线的收益。** 这不是放弃，是排序。

## 4. 完整交接（下一步是明确的）

要让 `equip` 成功、理念激活、进而读到 ramp 真实幅度，只需：

1. **确认槽的实际长度**：在 `write_f32_range` 之前读 `_slots[sid].arr_f32.size()`（需要一个探针或
   `component_stride` 类接口）；
2. 若长度 < CELLS，先让槽扩容（`register_component` 的 `stride` 参数不控制长度，
   可能需要 `create_entities` 或等价接口）；
3. 长度匹配后，`economy epoch` 应能打开；
4. epoch 打开 → economy 产出 class opinion → `equip` 的 `support_gate` 通过 →
   `location=1` → `seen>0` → `taken>0` → **ramp 真实幅度可读**。

**整条链路只剩「槽长度」一个未知数。**

## 5. 七轮的净收获

| 项 | 价值 |
|---|---|
| **秒级探针** | 10 秒 vs 10 分钟（60 倍）|
| `sequences` 幂等键 | 修掉了我自己的一个真 bug |
| 回执诊断法 | 无回执=未处理；status=2 成功、3 被拒并带原因 |
| 并行数组快照 | `idea_ids`/`locations`/`levels`/`slot_indices`/`transition_pending` |
| `register_component` 可注册槽 | 不依赖 MapData |
| **11 项否定清单** | 后续者不必重复试错 |
| 唯一剩余未知 | **槽长度** |

## 6. 验证

| 项 | 值 |
|---|---|
| 环境槽填充 | **10 / 10** |
| economy epoch | `economy_environment_snapshot_invalid`（前进一道门）|
| grant/discover/understanding | **status=2 成功** |
| equip | status=3 `ideology_class_opinion_unavailable` |
| 探针耗时 | 约 10 秒 |
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 / coverage 6-6 全 0 |
| 回归（rollout ON） | 零判定变化 |

## 7. 局限

- **仍未取得 ramp 真实幅度。**
- 槽长度未实测。
- 未尝试其他扩容路径。

## 8. 更重要的事：M3 的定位

**M3 的功能实现已完成**：
- 265/265 program 判定为 DerivedCell
- 逐格 ramp 求值器（13 checks）
- 物化器逐格求值（12 checks）
- rollout 打开到 `Continuous`，**回归零变化**
- 覆盖率 6/6

**缺的是「真实世界数值验证」**。这个区分必须保留：能力已交付，验证未完成。
