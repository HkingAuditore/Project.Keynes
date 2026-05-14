> **DEPRECATED 2026-05-14**：本文档已被
> [`dots-master-execution-handbook.md`](./dots-master-execution-handbook.md) §3 替代。
> Phase 2 数据所有权下移完整方案（含 G.4/G.5 等价内容）现集中在 master 手册 §3。
> 本文档保留以便 git history 追溯，**不再维护**。

# Phase G.4 + G.5：数据所有权下移执行计划（deferred）

> **当前状态**：scaffolding 就位，**等 F.1-F.6 填实际 C++ 算法 + bit-equal 验收
> 通过后**才能安全执行。本文档锁定 G.4/G.5 的前置依赖、执行步骤、验收标准。
>
> 配套 plan：[`dots_full_migration_dbfef566.plan.md`](../../../../.cursor/plans/dots_full_migration_dbfef566.plan.md)
> 配套规划：[`dots-migration-roadmap.md §3 A4`](./dots-migration-roadmap.md)（阶段 II）

---

## 1. 为什么 G.4/G.5 必须 deferred

阶段 II（HexCell facade / 砍 flush_soa_to_cells）改动量极大：
- ~30 个 HexCell 强类型字段全部改 facade（getter + setter 路径）
- ~300+ 处 `cell.<field> = ...` 写入点全部改为 `world.write_*`
- 任何遗漏 → 数据静默偏离（写到 GDScript 端但 C++ 端读旧值，反之亦然）

前置硬依赖：
1. **F.1-F.6 必须有真实 C++ 实现**（不是 stub）
   当前所有 7 个 `run_*_pass` stub 都返回 -1.0，GDScript caller 走 fallback。如果
   G.4 下移写路径到 `world.write_*`，但 hot pass 还是 GDScript（fallback 路径），
   那么写路径的同步策略复杂——GDScript fallback 写 `world.write_*` 需要保证
   与既有 `cell.<field> = ...` 等价（额外验证负担）。
2. **每个 hot pass bit-equal 验收通过**（charter §12.4 七步 SOP 跑完）
   必须先确认 C++ 端写入与 GDScript 端写入数值一致，才能安全把 fallback 路径也
   切到 `world.write_*`（避免双重切换造成的偏差）。
3. **ViewAdapter `use_world_view_adapter=true` 稳定一周**（B.3 的下游）
   读路径已稳定后，写路径才能放心下移。

---

## 2. 当前阻塞状态可视化

```
F.1 weather field   stub → -1.0   ← 阻塞 G.4 (weather hot pass 写)
F.2 ocean water     stub → -1.0   ← 阻塞 G.4 (ocean hot pass 写)
F.3 climate pass_b  stub → -1.0   ← 阻塞 G.4 (climate Pass-B 写)
F.4 sea_ice         stub → -1.0   ← 阻塞 G.4 (sea_ice 写 + terrain ECB)
F.5 transp          stub → -1.0   ← 阻塞 G.4 (transp 写)
F.6 weather front   stub → -1.0   ← 阻塞 G.4 (weather front pool 升权)
                                    ↓
                                G.4 (write paths → world.write_*)
                                    ↓
                                G.5 (delete flush + HexCell facade)
```

---

## 3. G.4 执行步骤（F 完成后）

### 3.1 前置检查

- [ ] 6 hot pass C++ 实现都已 bit-equal 验收（容差按 charter §12.5）
- [ ] `use_gdext_*` flag 都已 default=true 跑稳一周
- [ ] `use_world_view_adapter=true` 跑稳一周（读侧已统一走 view_f32）
- [ ] 所有 sub-baker 的实际函数搬迁完成（G.2 真正落地）

### 3.2 改造步骤（按依赖顺序）

#### Step G.4.1：climate Pass-A SoA fallback 路径

[`scripts/simulation/climate/pass_a.gd`](../Project/project-keynes/scripts/simulation/climate/pass_a.gd)
中 `_climate_pass_a_soa` 的 GDScript 写路径：

```gdscript
# 改前：
map.temp_arr[idx] = new_temp
map.moisture_arr[idx] = new_moist
# ...

# 改后：
world.write_f32(_cid_temp, idx, new_temp)
world.write_f32(_cid_moisture, idx, new_moist)
# 或批量：
world.write_f32_indexed(_cid_temp, dirty_indices, new_temps)
```

#### Step G.4.2-G.4.6：其他 5 hot pass 同样改造

每个 sub-pass 独立 PR + bit-equal 验收。

### 3.3 G.4 验收

- 30-day weather + climate pipeline bit-equal vs G.3 末态
- hot pass 改造前后字段数值 byte-equal（PackedFloat32Array 逐 idx 对比）
- 截图像素 diff < 0.1%

---

## 4. G.5 执行步骤（G.4 完成后）

### 4.1 前置检查

- [ ] G.4 已稳定运行一周（所有写路径走 `world.write_*`）
- [ ] `flush_soa_to_cells` / `rebuild_soa_from_cells` 已无业务必要（grep 不到非 baker / debug 调用方）

### 4.2 改造步骤

#### Step G.5.1：删除 flush_soa_to_cells

```gdscript
# scripts/geography/map_data.gd
# 删除整个 flush_soa_to_cells 函数（约 30 行）

# scripts/simulation/sus/jobs/refresh_climate_daily_job.gd::_finalize_round
# 删除调用：
# if cp_for_flush != null and bool(cp_for_flush.use_soa_pipeline) and map.has_soa():
#     map.flush_soa_to_cells()  ← 删
```

#### Step G.5.2：删除 rebuild_soa_from_cells

```gdscript
# scripts/geography/map_data.gd
# 删除整个 rebuild_soa_from_cells 函数（约 60 行）

# 调用方（generate 末尾）改为生成期直接写 SoA：
# 旧：generate → AoS（cell.field = ...）→ map.rebuild_soa_from_cells() → bind_map_data
# 新：generate → 直接写 SoA（map.<field>_arr[idx] = ...）→ bind_map_data
```

#### Step G.5.3：HexCell 字段改 facade

```gdscript
# scripts/geography/hex_cell.gd
# 改前：
var temperature: float = 0.0
var moisture: float = 0.0
# ... ~30 个字段

# 改后（约 30 个字段都这样）：
# Facade getter
func get_temperature() -> float:
    return _world.read_f32(_cid_temp, index) if _world != null else 0.0
# 取消 setter（写路径已全部走 world.write_*）

# 配套：HexCell._init 时把 _world / _cid_* 注入
```

#### Step G.5.4：调用点更新

`rg "cell\.\w+\s*=" -t gd` 全代码库 grep，逐处确认：
- 业务路径：已在 G.4 改为 `world.write_*` ✓
- 极少数残留（如生成期）：手动改为 `map.<field>_arr[idx] = ...` 直写 SoA
- 测试路径：保留（test 可以直接 mock cell.field = ...）

### 4.3 G.5 验收

- `rg "cell\.\w+\s*=" -t gd` 在 hot pass / refresh path 下结果接近 0
- `rg "flush_soa_to_cells|rebuild_soa_from_cells" -t gd` 全代码库 = 0
- 30-day soak: fast tick avg / p95 ±5%；截图像素 diff < 0.1%
- MapData 残留 ≤ 200 行（仅 topology + cell_array IO）

---

## 5. 风险 + 缓解

| 风险 | 缓解 |
|---|---|
| F 阶段算法 bit-equal 偏差未发现 → G.4 切换后偏差累积 | F.1-F.6 每个独立 PR + 各自 bit-equal bench；连续跑 30 day soak 验证 |
| HexCell facade 性能黑洞（每 cell.field 变成 world.read_f32 调用）| F.1-F.6 已 C++ 化后，业务 hot loop 不再走 cell.field；只有冷路径（UI / debug）走 facade，性能影响可接受 |
| 改造期间游戏跑不起来（编译/parse error）| 每个 sub-step 独立 PR + 编译验证 + 5 min 实机测试；不一次性大改 |

---

## 6. 完成后 checkpoint

- [ ] 所有 6 hot pass 真实 C++ 实现 + bit-equal 验收 + flag 默认 true
- [ ] G.4：6 hot pass 的写路径都走 `world.write_*`
- [ ] G.5：HexCell 所有强类型字段都是只读 facade；MapData 退化为 topology + IO
- [ ] `flush_soa_to_cells` 全代码库 0 引用
- [ ] 30-day soak: fast tick avg < 5ms / p95 < 10ms；截图像素 diff < 0.1%
- [ ] 文档：[`module-ownership-map.md`](./module-ownership-map.md) + [`dots-framework-status.md`](./dots-framework-status.md) 标记"完全 DOTS 化已完成"

完成上述全部 checkpoint 后才算"完全 DOTS 化"目标达成。

---

**END.**
