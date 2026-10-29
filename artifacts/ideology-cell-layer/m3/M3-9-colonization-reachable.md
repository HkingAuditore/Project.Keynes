# M3-9 殖民链路已打通，但没有任何可发起的报价

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **六道门全部通过**（`quote ok=true`）；但扫描 212 格 **`rows=0`** |
| 结论 | 殖民查询可达，**无可发起的殖民**；32 上限的玩法影响仍未定论 |

## 1. 本轮真正的突破：`quote ok=true`

自 M3-5 以来，所有殖民查询都返回 `colonization_target_invalid`。本轮首次拿到：

```
would_accept_target: true
quote ok=true rows=0
```

**六道门全部通过。**

## 2. 关键发现：顺序错了，而不是机制坏了

M3-8 我用 `sync_country_territory_to_map()` 把可见性从 0 变成 6144，但那一次**同时调用了 `_refresh_vision()`**，我误把功劳记给了 sync。

本轮先只调 sync，可见性**仍是 0**：

```
sync 单独调用  -> visible_nonzero = 0
sync + _refresh_vision -> visible_nonzero = 6144
```

读源码确认：`sync_country_territory_to_map()` **完全不写 `visible_arr`**（`world_ext_country.cpp:1848-1862`，只发布领土槽）。

**正确的顺序是：先 sync 领土 → 再 refresh 视野。** 视野需要领土数据才能算。

这个错误与前面的模式一致：**我把「两个动作一起做后的结果」归因给了其中一个。**

## 3. 但没有任何可发起的报价

修好顺序后，扫描 212 个格：

```
[pass] BEST quote cell=-1 rows=0 after scanning 212
```

**每一个格都 `ok=true` 且 `rows=0`。**

含义：所有前置条件都满足，但**没有任何家族有能力/意愿在该格殖民**。报价列表由家族资金、距离、可见性等综合决定，这里是空的。

## 4. 这说明什么

| 问题 | 答案 |
|---|---|
| 殖民机制存在吗？ | ✅ 存在且完整 |
| 无头夹具能调通殖民查询吗？ | ✅ **本轮打通** |
| 能发起殖民吗？ | ❌ 没有可用报价 |
| 32 上限会被触发吗？ | ❓ **仍未知** |

**领土增长需要报价，报价需要家族资源与条件。** 开局世界里家族可能太弱或太远，所以没有报价。

## 5. 本轮的三个自我纠正

| # | 我的判断 | 实际 |
|---|---|---|
| 1 | sync 修好了可见性 | 是 `_refresh_vision()` 修的；sync 只是提供数据 |
| 2 | 剩下的是 epoch 门 | `target_passable=true`，epoch 门不是阻碍 |
| 3 | 探针的 census 正常运行 | `sampled=0`，while 循环根本没进（`WIDTH * HEIGHT` 的类型问题）|

第 3 条说明**我的探针本身也要被验证**——一个从不执行的循环会打印出「0 个可通行格」，与「地图上确实没有」完全同形。

## 6. 现在的完整知识

六道门及其满足方式（全部实证）：

| 门 | 满足方式 |
|---|---|
| 运行时 bootstrapped | `generate_world` |
| 国家 handle 有效 | `get_country_cell_summary(cell).country_handle` |
| 目标不越界 | 采样格合法 |
| 可见性 | **`sync_country_territory_to_map()` → `_refresh_vision()`** |
| 主权允许 | 无主格（`owner_handle=0`）|
| 贸易拓扑就绪 | `generate_world` 后自动 |
| `passable != 0` | 陆地格（如 cell 901）|

第七项（epoch）在 `passable != 0` 时不构成阻碍。

## 7. 验证

| 项 | 值 |
|---|---|
| `quote ok` | **true**（首次）|
| `would_accept_target` | **true** |
| `visible_nonzero` | 0 → **6144** |
| 扫描格数 | 212 |
| 最大 rows | **0** |
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 全 0 |

## 8. 局限

- **没有产出一笔成功的殖民**，所以「领土能否超过 32 格」仍未验证。
- `rows=0` 的原因未查（家族资金？距离？初始家族太少？）。
- census 的 `sampled=0` 说明第一段统计无效，`passable=0` 这个数字不可信（`first_passable=901` 是循环外的旧值）。
- 未尝试人为补充家族资金后再取报价。

## 9. 下一步（两条路，都不贵）

1. **提高家族资源后重试**：给某家族足量资金，再看报价是否出现——这能直接区分「资源不足」与「机制不通」。
2. **转向 M3 的 D 类**（41 个条件常数）：殖民这条线已经花了 5 轮，主线被搁置太久。

**我倾向先做 1（一次探针即可），然后无论结果如何都转回 2。**

## 10. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_colonization_passable_probe.gd'
# => quote ok=true rows=0 ; BEST cell=-1 rows=0 after scanning 212
```
