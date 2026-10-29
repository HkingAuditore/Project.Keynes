# M3-8 殖民门逐道拆解：可见性已打开，剩下 epoch 门

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **可见性门已打通**（`visible_nonzero` 0 → 6144）；剩下一道此前未发现的 epoch 门 |
| 结论 | 六道门已定位五道，最后一道需要 ACTIVE epoch |

## 1. 本轮确证的四件事

### 1.1 `country_slot_arr` 只有一个写入点

```gdscript
# world_runtime_host.gd:1647
_current_map.country_slot_arr = full_owners
```

所在函数是 `_consume_country_worker_read_view_if_authoritative()`（`:1604`）——**只在 worker 权威模式下运行**。

无头夹具从不触发它，所以平面一直是空的。这解释了 M3-7 的 `size=0`。

### 1.2 `sync_country_territory_to_map()` 能修好可见性

```
AFTER sync DIAGNOSIS: visible_nonzero=6144, target_visible=true
（调用前：visible_nonzero=0, target_visible=false）
```

**从全 0 变成全 6144 可见。** 这是本轮最硬的收获。

### 1.3 但殖民报价仍然失败

```
AFTER sync quotes ok=false code=colonization_target_invalid rows=0
```

所以可见性**不是**最后一道门。

### 1.4 我原先漏掉了两道门

读完 `family_colonization_quotes` 的全部返回点，`colonization_target_invalid` 有 **四个**来源，我此前只知道两个：

| 行 | 条件 | 我此前知道吗 |
|---|---|---|
| `:462` | 目标越界 | ✅ |
| `:474` | `visible[target] == 0` | ✅ |
| **`:487`** | `!colonization_target_owner_allowed` | ✅（诊断显示 `owner_allows=true`）|
| **`:496`** | **`passable[target] == 0 && !_epoch_active`** | ❌ **漏了** |

`diagnose_colonization_target` 只覆盖了前三个，所以它报「一切正常」而报价仍然失败。

**这是我这轮差点再次误判的地方**：如果只看诊断桥，会得出「所有门都开着但调用失败」的矛盾结论。

## 2. 剩下那道门的确切含义

```cpp
// economy_runtime_colonization.cpp:496
if (_trade_topology.passable[target_cell] == 0 && !_epoch_active) {
    out["code"] = "colonization_target_invalid";
```

一个**没有贸易通路的格**，在 epoch 未激活时被拒绝。日志显示 `topology_ready=true`，所以 `passable` 数组存在；问题在于目标格的 passable 值为 0，而 `_epoch_active` 为 false。

**所以要打开一个活跃 epoch。**

`begin_or_reuse_economy_input_epoch(day_index, generation)` 已绑定到 GDScript（`world_ext_bind_methods.cpp:773`），我在探针里调了它，但在结果打印前被杀掉，**结果未取得**。

## 3. 我本轮的两次自我纠正

| 判断 | 实际情况 |
|---|---|
| 「sync 之后应该就好了」 | 没好，还有 epoch 门 |
| 「诊断桥报全绿所以门都开着」 | 诊断桥只覆盖 3/4 道门，遗漏 `:496` |

第二条值得单独记：**诊断工具本身可能不完整，它会给出「一切正常」的假象。** 补全的方式是读源码里的**全部**返回点，而不是相信自己写的探针覆盖度。

## 4. 当前的完整门的清单

| 门 | 状态 | 如何满足 |
|---|---|---|
| 运行时可用 / 已 bootstrap | ✅ | 已满足 |
| 国家 handle 有效 | ✅ | `get_country_cell_summary` → `4294967300` |
| 目标越界 | ✅ | 采样均合法 |
| 可见性 | ✅ | **`sync_country_territory_to_map()`** |
| 主权允许 | ✅ | `owner_handle=0`（无主）|
| 贸易拓扑就绪 | ✅ | 日志 `topology_ready=true` |
| **`passable==0 && !_epoch_active`** | ❓ | **需要 ACTIVE epoch** |

## 5. 验证

| 项 | 值 |
|---|---|
| `visible_nonzero` 变化 | **0 → 6144** |
| `country_slot_arr` 唯一写入点 | `world_runtime_host.gd:1647` |
| `target_invalid` 返回点总数 | **4**（我此前只知 3）|
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 / eligibility 56 全 0 |

## 6. 局限与下一步

- **epoch 门未验证**：`begin_or_reuse_economy_input_epoch` 的返回值没拿到（进程在打印前被杀）。
- `country_slot_arr` 仍为 `size=0`（sync 写的是另一个槽），但它不影响可见性——**可见性来自 sync，不是来自 `country_slot_arr`**。这个区分是本轮才搞清的。
- **32 上限的玩法影响仍未知**，自 M3-5 起没有实质推进。
- 采集 29 个格点的循环太慢（世界生成 + 每次 quotes 都有成本），应该只测 2–3 个格点。

**下一步很明确**：单独跑一次只测 `begin_or_reuse_economy_input_epoch` + 单个 quotes 的最小探针，确认 epoch 门。

## 7. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_colonization_gate_probe.gd'
# => 调用 sync 前 visible_nonzero=0；调用后 6144；quotes 仍 target_invalid
```
