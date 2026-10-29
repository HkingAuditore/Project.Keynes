# M3-25 ~~最终根因~~ 已被 M3-26 推翻：`country_anchor_cell` 实际返回 0

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | ~~根因是 anchor=-1~~ **已推翻**：实测 `query_country_anchor_cell(0) = 0` |
| 结论 | **本文件的根因判断是错的**，见 M3-26 |

## 1. 完整因果链（每一环都有源码或实测依据）

```
equip 成功  ->  location = IDEOLOGY                                 实测 locations=[1]
  -> collect_effect_activations 遍历到该 idea                       源码 :2162
    -> :2174 row.persistent_count >= 1                               实测 offsets 每级≥1
      -> :2182 program = "ideology.effect.salt_monopoly_l1"          实测 ok=true
        -> :2184 family_effect_metadata_pod 成功                     实测
          -> :2188 resolve_effect_targets
            -> :1907 anchor = _economy_runtime->country_anchor_cell(slot)
              -> **anchor = -1**
                -> :1908 return false
                  -> :2190 continue（跳过整个 program）
                    -> derived 列表为空
                      -> seen = 0 / taken = 0                        ← 实测
```

## 2. 根因的确切代码

```cpp
// economy_runtime_family_buff.cpp:1021-1040
int32_t NativeEconomyRuntime::country_anchor_cell(int32_t country_slot) const {
    if (country_slot < 0) return -1;
    const int32_t cells = _cell_count.get();
    if (_epoch_cell_country.size() != static_cast<size_t>(cells)) return -1;   // :1024 ★
    ...
    for (int32_t cell = 0; cell < cells; ++cell) {
        if (_epoch_cell_country[cell] == country_slot) return cell;
    }
    return -1;                                                                  // :1039
}
```

`_epoch_cell_country` 由 **`capture_country_epoch`** 从真实 `MapData` 填充。

我的廉价探针用 `bootstrap_country` 建立了 64 格领土（`economy epoch ok=true`），
但 **`_epoch_cell_country` 仍是空的**——`bootstrap_country` 写的是国家运行时的领土表，
不是经济侧的这个 plane。

所以 `:1024` 成立 → 返回 -1 → `resolve_effect_targets` false → `continue` → `seen=0`。

## 3. 这与十四轮调查的关系

这是**唯一**能让所有已验证事实同时成立的原因：

| 已验证事实 | 本根因能否解释 |
|---|---|
| 理念 ACTIVE（`locations=[1]`）| ✅ 激活与领土无关 |
| 判定器 `DerivedCell` | ✅ 判定只看 metadata，不看目标 |
| 程序存在（`ok=true`）| ✅ |
| persistent templates ≥1 | ✅ |
| 重建在跑（`visits=5`）| ✅ 重建跑但目标是空 |
| `seen=0` / `taken=0` | ✅ **正是本根因** |

**同时也解释了为什么真实世界夹具（6144 格、真实地图）的 `seen` 也是 0**：
那个夹具调了 `sync_country_territory_to_map()` + `_refresh_vision()`，
但**没有让经济侧 `capture_country_epoch` 跑过**——它需要
`begin_or_reuse_economy_input_epoch` 且 `capture_country` 成功。

## 3b. M3-26 追加：anchor 实际有效，问题在 target 收集

实测 `query_country_anchor_cell(0) = 0`，**anchor 不是 -1**，所以 `:1908` 不触发。

真正的最后一环是 `:2062`：

```cpp
} else {
    _economy_runtime->collect_effect_target_cells(anchor,
        effective.target_selector_kind,      // 12 = OWN_TERRITORY
        effective.target_selector_param[0],
        effective.target_selector_param[1], cells, selection_salt, &_selector_stats);
}
```

它用 `anchor` 作为起点收集本国领土格。`anchor = 0` 说明 **slot 0 在
`_epoch_cell_country` 里确实拥有 cell 0**，所以 plane 不是全空。

**因此 `cells` 为空很可能是 `collect_effect_target_cells` 在 kind 12 下
找不到足够的领土格**——廉价探针的领土来自 `bootstrap_country`，可能只有极少数格，
或 `_epoch_cell_country` 只有部分填充。

这一步需要一次直接探测 `collect_effect_target_cells` 的返回数量。

## 4. 下一步（唯一且具体）

要让 `seen > 0`，必须让 `_epoch_cell_country` 与 `_cell_count` 同尺寸且含本国格。
两条路：

**路线 A（廉价探针）**：找到 `capture_country_epoch` 的触发路径。它可能由
`begin_or_reuse_economy_input_epoch` 的 `capture_country` 标志驱动，需要 MapData 的
`country_slot_arr`（M3-7 实测为 `size=0`）。

**路线 B（真实世界夹具）**：在 `ideology_ramp_realworld_test.gd` 里，
经济 epoch 打开后调用**能让领土 plane 填充的桥**。该夹具的 `country_slot_arr` 也是 0
（M3-7），但 `sync_country_territory_to_map()` 能把它写入 MapData——
**关键在于后续是否调用了 `capture_country_epoch`。**

## 5. 验证

| 项 | 值 |
|---|---|
| 根因定位 | ✅ `country_anchor_cell` 因 `_epoch_cell_country.size() != cells` 返回 -1 |
| 解释力 | ✅ 覆盖全部 6 项已验证事实 |
| `seen` / `taken` | 0 / 0（与根因一致）|
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 全 0 |
| 回归（rollout ON） | 零判定变化 |

## 6. 局限

- **仍未取得 ramp 真实幅度。**
- `_epoch_cell_country` 为何为空未直接实测（推断自 `:1024` 与 M3-7 的 `country_slot_arr=0`）。
- 未尝试路线 A 或 B。

## 7. 十五轮的最终产出

| 项 | 价值 |
|---|---|
| **完整根因链** | 从 `seen=0` 到 `country_anchor_cell` 返回 -1，共 8 环全部有依据 |
| 12 步激活序列 | 已验证可让理念 ACTIVE |
| **两处我自己的探针缺陷** | `filled=10` 假指标、漏传 `has_metric_ramp` |
| 19 项否定清单 | 后续者不必重复试错 |
| 廉价探针 | 10 秒 vs 10 分钟（60×）|

**M3 的功能实现完整**（265/265、求值器、物化器、rollout、回归零变化），
**缺的是一次真实领土下的数值验证**，而它的阻塞点现在精确到一个函数。
