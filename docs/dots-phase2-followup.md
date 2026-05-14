> **DEPRECATED 2026-05-14**：本文档已被
> [`dots-master-execution-handbook.md`](./dots-master-execution-handbook.md) §3 替代。
> Phase 2 完整执行方案（PR-2.0 + PR-2.passA-unblock + PR-2.1.x + PR-2.2 + PR-2.3）现集中在 master 手册。
> 本文档保留以便 git history 追溯，**不再维护**。

# Phase 2 — Stage II 数据所有权下移：Follow-up 设计

> 状态：**Phase 1（数据层 C++ 闭环）已就位 → 进入硬前置等待期 → Phase 2 启动条件由用户验收触发**
> 关联：[`dots-migration-roadmap.md`](./dots-migration-roadmap.md) §G / [`dots-stage-ii-data-ownership-plan.md`](./dots-stage-ii-data-ownership-plan.md) §3
> 创建：2026-05-14

---

## 0. Phase 2 启动前置条件

不能立刻启动 Phase 2，必须等：

- [x] F.1 / F.2 / F.3 / F.5 已 C++ 化 + 验收 ✅
- [x] F.4 sea_ice C++ 已实装（本批 PR）✅ 等用户编译 + 启 flag 验收
- [x] F.6 weather front advect C++ 已实装（本批 PR）✅ 等用户编译 + 启 flag 验收
- [ ] **6 个 use_gdext_*=true 默认开稳一周（charter §12.5 验收周期）**
- [ ] **use_world_view_adapter=true 稳一周（已有，非阻塞）**

只要前 2 项中"等编译验收" 的部分用户跑稳了，Phase 2 即可启动。

---

## Phase 2.1 — 6 hot pass 写路径下移（W7-W11，~6 个独立 PR）

### 共享改造模板

每个 pass 的改造模式：

```gdscript
# ─── 改前（cell.field= 或 map.field_arr[]= 模式）───
for i in range(n_cells):
    var c: HexCell = cells[i]
    var new_temp: float = compute_temp(c, ...)
    c.temperature = new_temp                     # ← cell.field=
    map.temp_arr[i] = new_temp                   # ← map.field_arr[]= 同时

# ─── 改后（world.write_f32_indexed 单一 SoA 写）───
var dirty_indices: PackedInt32Array = PackedInt32Array()
var new_temps: PackedFloat32Array = PackedFloat32Array()
# ... 收集 ...
_world.write_f32_indexed(_cid_temp, dirty_indices, new_temps)
# cell.field= / map.field_arr[]= 全部删除（HexCell facade 阶段会从 SoA 读）
```

### PR 序列（每 PR 独立，bit-equal 30-day soak 验收）

| PR | 文件 | 字段 | 写点估算 |
|---|---|---|---|
| PR-2.1.1 climate Pass-A SoA fallback | [`pass_a.gd`](../Project/project-keynes/scripts/simulation/climate/pass_a.gd) | cell.temp / temp_baseline / temp_30d / temp_365d / temp_anomaly / temp_season_offset | ~25 处 |
| PR-2.1.2 climate Pass-B | [`pass_b.gd`](../Project/project-keynes/scripts/simulation/climate/pass_b.gd) | cell.temp / cell.moisture | ~12 处 |
| PR-2.1.3 ocean water+land | [`water_pass.gd`](../Project/project-keynes/scripts/simulation/ocean/water_pass.gd) + [`land_pass.gd`](../Project/project-keynes/scripts/simulation/ocean/land_pass.gd) | cell.temp / cell.temperature_transport_anomaly | ~8 处 |
| PR-2.1.4 sea_ice daily | [`daily_pass.gd`](../Project/project-keynes/scripts/simulation/sea_ice/daily_pass.gd) | cell.sea_ice_fraction | ~3 处（terrain 翻转走 apply_terrain，不在本 PR） |
| PR-2.1.5 transpiration | [`transpiration_pass.gd`](../Project/project-keynes/scripts/simulation/biology/transpiration_pass.gd) | cell.moisture | ~2 处（最简单，建议作为模板 PR 先做） |
| PR-2.1.6 weather field | [`weather_system.gd`](../Project/project-keynes/scripts/weather/weather_system.gd) | cell.weather_* (7 字段) | ~30 处 |

### 通用注意点

1. **F.x C++ 路径已经写 SoA**：本 PR 改的是 GDScript fallback 路径（C++ flag=false 或 ext=null 时跑），所以**只在 fallback 段改**，不动 fast-path；
2. **HexCell 字段同步暂留**：阶段 III HexCell facade 化（PR-2.3）之前，cell.field 仍是真实字段；本 PR 改完后 cell.field= 改成"先 write_f32 再 cell.field=同值"双写一段时间，方便随时回滚；
3. **`_cid_*` 字段**：每个 pass 入口处一次性 cache `_cid_temp = world.component_id(...)` 避免 hot loop 反射；
4. **dirty_indices 收集**：可用 `PackedInt32Array.append(idx)` per dirty cell，或用 `PackedByteArray dirty_mask + 末尾 collect` 两种模式选一；
5. **bit-equal 验收**：跑 30-day soak 两遍（旧路径 / 新路径），逐 cell 对比 cell.temp / cell.moisture / cell.sea_ice_fraction 数值差 < 1e-6（charter §12.5 容差表）。

---

## Phase 2.2 — 删除 flush_soa_to_cells / rebuild_soa_from_cells（W12-W13，~2 PR）

### PR-2.2.1 删除 flush_soa_to_cells

**前置**：Phase 2.1 全部完成（hot pass 写路径已下移到 SoA，HexCell.field= 仅作"为 UI / Baker 兜底的双写"）。

**操作**：
1. 删除 [`map_data.gd::flush_soa_to_cells`](../Project/project-keynes/scripts/geography/map_data.gd) (~30 行)
2. 调用方清理：
   - [`refresh_climate_daily_job._finalize_round`](../Project/project-keynes/scripts/simulation/sus/jobs/refresh_climate_daily_job.gd) 末尾 `map.flush_soa_to_cells()` 调用
   - 任何 Phase 2.1 完成时还残留的"双写之后再调一次 flush"调用
3. 验收：`rg "flush_soa_to_cells" -t gd` = 0

### PR-2.2.2 删除 rebuild_soa_from_cells

**操作**：
1. 删除 [`map_data.gd::rebuild_soa_from_cells`](../Project/project-keynes/scripts/geography/map_data.gd) (~60 行)
2. 调用方清理：
   - generate 末尾的 `rebuild_soa_from_cells` 调用 → 改为生成期直接写 SoA（用 `_alloc_soa` + `cells[i].field` 一次性 init 写入）
3. 验收：`rg "rebuild_soa_from_cells" -t gd` = 0

---

## Phase 2.3 — HexCell 30 字段改只读 facade（W13-W14）

### 改造模板

```gdscript
# ─── 改前（hex_cell.gd 字段是 var）───
var temperature: float = 0.0
var moisture: float = 0.0
# ... 30 个强类型字段 ...

# ─── 改后（getter facade，setter 全部移除）───
var _world: DCWorld = null
var _cid_temp: int = -1
var _cid_moisture: int = -1
# ...

func get_temperature() -> float:
    if _world == null:
        return 0.0
    return _world.read_f32(_cid_temp, index)

func _to_string() -> String:
    return "HexCell(%d,%d) temp=%.2f" % [q, r, get_temperature()]
```

**HexCell._init 注入**：
```gdscript
func _init(p_q: int = 0, p_r: int = 0, p_world: DCWorld = null) -> void:
    q = p_q
    r = p_r
    s = -p_q - p_r
    _world = p_world
    if p_world != null:
        _cid_temp = p_world.component_id(DCComponentIds.CELL_TEMP)
        _cid_moisture = p_world.component_id(DCComponentIds.CELL_MOISTURE)
        # ... 30 个字段 cid cache
```

### PR-2.3.1 残留扫荡

```bash
rg "cell\.\w+\s*=" -t gd
```

应该 0 或仅剩下：
- 生成期初始化（`map_generator._build_initial_world` 等）
- 测试 mock（`tests/*.gd`）
- 已知 cold path（debug overlay / inspector）

业务路径如还有 `cell.field=` 残留 → 该 PR 必须把它们改成 `world.write_f32(...)` 形式。

### Phase 2.3 验收

- `rg "cell\.\w+\s*=" -t gd` 在 hot path 下 = 0（业务路径）
- 30-day soak fast tick avg ±5%
- 截图像素 diff < 0.1%（visual 路径不变）

---

## Phase 2 总验收

完成全部 Phase 2 后：
- MapData 残留 ≤ 200 行（仅 topology + IO）
- HexCell 是 30 字段 thin facade
- 数据所有权完全在 DCWorld（C++）+ MapData(_arr) 镜像

---

**END.**
