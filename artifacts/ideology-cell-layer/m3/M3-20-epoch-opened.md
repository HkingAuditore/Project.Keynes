# M3-20 突破：economy epoch 首次成功打开

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **`economy epoch ok=true`（首次）**；`entity_count 0 → 64` |
| 结论 | 缺失的最后一步是**先建实体再注册槽**；`equip` 仍差 class opinion |

## 1. 本轮的关键突破

```
[q] entity_count before=0 after=64
[q] environment slots filled=10 of 10
[q] economy epoch ok=true reason=
```

**经济 epoch 第一次成功打开。** 此前七轮一直停在
`required_environment_slot_missing` / `economy_environment_snapshot_invalid`。

## 2. 为什么之前一直失败

```cpp
// world_ext.cpp:405-415
void DCWorldExt::write_f32_range(int comp_id, int start, const PackedFloat32Array &src) {
    ...
    ERR_FAIL_COND(start + n > s.arr_f32.size());   // :411 ← 不扩容，静默失败
```

槽长度由 **`_entity_count`** 决定：

```cpp
// register_component
if (_entity_count > 0) _ensure_slot_capacity(s, _entity_count);   // :182-185
// create_entities
for (int i = 0; i < _slots.size(); ++i)
    _ensure_slot_capacity(_slots.write[i], _entity_count);        // :226-228
```

**裸 ext 的 `_entity_count == 0`**，所以注册出来的槽长度为 0，所有 `write_*_range`
都被 `ERR_FAIL_COND` 静默拒绝。探针却报告 `filled=10 of 10`（因为我只检查了 `sid >= 0`）。

**修正：先 `create_entities(CELLS)`，再注册槽，再写入。**

## 3. 这是我自己的探针在说谎

```gdscript
if sid >= 0:
    ext.write_f32_range(sid, 0, zeros_f32)
    filled += 1        // ← sid 有效就 +1，完全没检查写入是否成功
```

`write_f32_range` 返回 `void`，**无法知道它失败了**。所以「filled=10 of 10」是一个
基于「槽存在」而非「数据写进去了」的假指标。

**教训：当写入 API 返回 void 且内部有 `ERR_FAIL_COND` 时，「调用成功」不等于「生效」。**

## 4. 仍然缺的一步

```
receipts count=4 statuses=[2,2,2,3] reasons=["","","","ideology_class_opinion_unavailable"]
equip-settle day=0 idea_ids=1 locations=[0] levels=[2] active=0 applied=1
```

`equip` 仍被 `support_gate(SUPPORT_ADOPT)` 拒绝，需要 class opinion。

而 `run_economy_slice({"day_index":0,"tick_index":0})` 返回 `ok=? done=true` —— **`ok` 字段缺失**，
说明该调用仍未真正运行经济（正确形状来自 `building_resource_chain_test.gd:417`，
但那个夹具还先做了别的配置）。

## 5. 验证

| 项 | 值 |
|---|---|
| `entity_count` | **0 → 64** |
| 环境槽 | 10 / 10（且现在数据真的写入了）|
| **economy epoch** | **ok=true（首次）** |
| grant / discover / understanding | status=2 成功 |
| equip | status=3 `ideology_class_opinion_unavailable` |
| `levels` | 0 → 2 |
| 探针耗时 | 约 10 秒 |
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 / coverage 6-6 全 0 |

## 6. 剩余的最后一步

`run_economy_slice` 需要一个能真正推进经济的调用形状。`building_resource_chain_test.gd`
在调用它之前先做了完整的经济 bootstrap（population packet、market packet）。

**具体下一步**：读 `building_resource_chain_test.gd:400-420`，照抄它的 bootstrap + slice 序列。

## 7. 局限

- **仍未取得 ramp 真实幅度。**
- `run_economy_slice` 的 `ok` 字段缺失，未查明。
- 未尝试 `bootstrap_economy`。

## 8. 八轮的完整结论

| 层 | 状态 |
|---|---|
| ramp 判定（265/265） | ✅ |
| 逐格求值器 | ✅ 13 checks |
| 物化器逐格求值 | ✅ 12 checks |
| rollout 打开 + 回归零变化 | ✅ |
| 理念命令协议 | ✅ 全部打通（grant/discover/understanding 成功）|
| **economy epoch 打开** | ✅ **本轮** |
| economy 真正运行 | ❌ 下一步 |
| class opinion → equip | ❌ |
| **ramp 真实幅度** | ❌ |

**前六项已完成。后四项是同一条链，已推进到「只差 economy slice 的调用形状」。**
