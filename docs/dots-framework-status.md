# Project.Keynes — DOTS 框架现状速查（onboarding 必读）

> **2026-05-14 更新（"完成全面DOTS化与Block B C++" plan 主体完成）**：DOTS 主指挥手册 28 周方案 + Block B C++ 实装 + HexCell 21 字段 facade + flush_soa 删除全部完成。
> 详见 [dots-master-execution-handbook.md](./dots-master-execution-handbook.md) +
> [dots-block-e-acceptance.md](../Project/project-keynes/docs/dots-block-e-acceptance.md)。
>
> **当前阶段达成**：
> - ✅ Phase 2（数据所有权下移）：write_indexed API + 7 hot pass 写路径下移 + **PR-2.3b HexCell 21 字段 facade（cid 缓存 + 双写）** + **PR-2.4 flush_soa 删除**
> - ✅ Phase 4（持久化 + 工程化）：serialize round-trip / migration ops / soak fixture / hot-reload signal
> - ✅ Block B（ocean wind C++）：**`DCWorldExt::run_wind_field_pass` ~470 LOC C++ 完整实装（wind_belt_speed_at + 季风 BFS + 山脉绕流）**；待 user `scons` 编译 + `use_gdext_wind_field=true` 切换 + `dots-wind-validation.md §3` 验收
> - 🟡 Phase 3（巨石拆分）：4 巨石蓝图 + stub 全部就位；3 个示范 PR 完成（PR-3.1.1 atlas_encoders + **PR-3.3.1 climate_math** + **PR-3.4.1 dots_bootstrap**），剩余 ~50 个机械搬迁 PR 留待后续会话推进
>     - 后续 PR 见 master 手册 §6.2-6.5 + dots-block-e-acceptance.md §3.2
> - ⏳ Phase IV（SIMD/threading）：preplan only；触发条件未达成，**不主动启动**
>
> 本文档是新加入开发者的 1-day 速读入口。读完后你应该能：
>
> - 知道当前 DOTS 框架处于什么状态（哪些抽象可用、哪些 still pending）
> - 知道想动 X 模块该读哪份文档、按什么 SOP 走
> - 知道项目的"反模式"边界在哪里，以及为什么
>
> 本文档不再重复 review / roadmap / charter / spec 已经写过的内容；它只
> 提供**导航 + 状态板**。

---

## 1. 30 秒速读：现在 DOTS 框架长什么样

```
✅ 数据层
   ├─ 38 个 cell-level component 由 ComponentSchema (A1) 单一源管理
   ├─ DCWorld 持有 component / pool / archetype / ECB
   └─ DCWorldExt (C++) hot loop 已支持：
      ├─ climate Pass-A / temp_drift / thermal_gradient / demo_complex
      ├─ F.1 weather field solve 完整算法实装 ✅ 已验收 (kernel 0.19ms vs 13ms，超 10x 目标)
      ├─ F.5 transpiration pass 完整算法实装 ✅ 已验收 (kernel 0.02ms vs 3.2ms，超 15x 目标)
      ├─ F.3 climate Pass-B 完整算法实装 ✅ 已验收 (kernel 0.07ms vs 5.2ms，超 7x 目标)
      ├─ F.2 ocean water+land 完整算法实装 ✅ 已验收 (water 0.09ms / land 0.02ms 双超 5x)
      ├─ Block B run_wind_field_pass 完整算法实装 ✅ 待 scons 编译验收 (35.55ms p95 → 目标 < 5ms)
      └─ F.4/F.6 2 个 stub（return -1.0；性能未构成瓶颈，由 plan §7 边界定为本期不做）

✅ 读侧
   └─ DCViewAdapter (B2) — UI / renderer / baker 通过 adapter.get_<field>(idx) 读

✅ 系统层
   ├─ DCSystem 基类 (A2) — 自动 cid cache + SusJob 兼容
   ├─ DCSystemScheduler (A3) — SUS+DCEcs 合并 + reads/writes 拓扑校验
   └─ 6 个生产 system 改写完成（3 原生 + 3 wrapper）

✅ 工程化
   ├─ FeatureFlagRegistry (B1) — 24 个 flag 集中索引（含 7 个 use_gdext_*）
   ├─ Module Manifest (B1) — Resource 类，每模块一份
   └─ MigrationHarness (B3) — 4 个模板文件（template_bench / template_module_test /
      template_overlay / README）

🟡 模块边界（拆分骨架就位 + facade 接口固化；实际函数搬迁待后续 PR）
   ├─ map_baker.gd 2583 行 → 5 sub-baker 骨架（B.2 + G.2 推荐迁移顺序）
   ├─ weather_system.gd 2142 行 → 5 sub-module facade（D.1 + E.1+E.2 详细 line range）
   ├─ map_generator.gd 4639 行 → 8 sub-module facade（D.2 + E.4-E.6 详细 line range）
   └─ main.gd 1901 行 → 5 bootstrap/UI 骨架（D.3 + G.3 推荐迁移顺序）

📋 dots-full-migration Phase F-G 已规划但待执行
   ├─ F.1: ✅ 实装 + 验收通过 (实测 kernel 0.19ms / weather_refresh 17→7.79ms)
   ├─ F.5: ✅ 实装 + 验收通过 (实测 kernel 0.02ms / refresh_climate_daily 10.10→8.81ms)
   ├─ F.3: ✅ 实装 + 验收通过 (实测 kernel 0.07ms / B field 5.9→0.6ms / fast tick 25→13ms)
   ├─ F.2: ✅ 实装 + 验收通过 (water 0.09ms / land 0.02ms / ocean field 6.3→0.9ms)
   ├─ F.4/F.6: 2 个 stub；按 F.1+F.5+F.3+F.2 套路逐个 PR 复用
   ├─ G.4-G.5: 数据所有权下移（HexCell facade / 砍 flush）→ 锁定在
   │           dots-stage-ii-data-ownership-plan.md，等 F 完成后启动
   └─ E/G 巨石实际函数搬迁（每函数独立 PR）

⏳ 阶段 III / IV（不在 dots-full-migration 范围内）
   ├─ DCWorld serialize / deserialize（存档系统接入）
   └─ SIMD / WorkerThreadPool（条件触发，charter §3.1 / §3.2）
```

---

## 2. "我想做 X，从哪份文档开始？"

| 我想做的事 | 入口文档 |
|---|---|
| 加一个新 cell-level 字段 | [`dots-component-schema.md §3`](./dots-component-schema.md) — 5 步 SOP |
| 加一个新 system（economy / unit / AI / pollution …） | [`dots-migration-roadmap.md §5`](./dots-migration-roadmap.md) — 7 步 SOP + [`tools/migration_harness/README.md`](../Project/project-keynes/tools/migration_harness/README.md) |
| 写一个新 hot-loop pass（C++ 化） | [`performance-charter.md §12.4`](./performance-charter.md) — 7 步操作清单 |
| 给 baker / UI 加新字段读取 | [`dots-view-adapter-guide.md §3`](./dots-view-adapter-guide.md) — 30 分钟 SOP |
| 改既有 system 的 reads/writes 声明 | [`dots-system-design.md §2.2`](./dots-system-design.md) — declare_* 系列 |
| 拆分一个巨石模块 | 看 D.1 / D.2 / D.3 骨架文件顶部 TODO，按优先级逐函数搬迁 |
| 加新 feature flag | [`feature_flags.gd`](../Project/project-keynes/scripts/data_core/feature_flags.gd) FLAGS 表 + 同步加 ClimateProfile @export 字段 |
| 跑性能 micro-bench | [`tools/migration_harness/template_bench.gd`](../Project/project-keynes/tools/migration_harness/template_bench.gd) 拷贝改 8 处 |
| 设计 SIMD / 多线程 | **先停**，去读 [`performance-charter.md §3.1 / §3.2`](./performance-charter.md) 触发条件；不满足条件不准做 |
| 看历史决策 / 为什么这么做 | [`DOTS review.md`](./DOTS%20review.md) + [`dots-experiment-report.md`](./dots-experiment-report.md) |
| 看每个模块的 owner / reads / writes | [`module-ownership-map.md`](./module-ownership-map.md) |

---

## 3. 五大铁律（一定要记住）

来自 [`performance-charter.md §0`](./performance-charter.md)：

1. **跨语言调用次数 = 性能上限**：永远不要在 GDScript 里 for 循环按 cell 调 C++
2. **SIMD / 多线程是带触发条件的优化**，不是默认手段（charter §3.1 / §3.2）
3. **先量再优**：没有 micro-bench 不动手，bench 模板见 migration_harness
4. **GDExtension 没有零拷贝共享内存**：snapshot + flush 是唯一可靠通信契约（charter §11）
5. **schema 单一源**：加新 component 必须走 [`component_schema.gd`](../Project/project-keynes/scripts/data_core/component_schema.gd)，禁止手写 BIND_TABLE

---

## 4. 当前限制 / Future iteration

### 4.1 框架硬化未完成的事（incremental work）

- **巨石拆分骨架→实现**：B.2 / D.1 / D.2 / D.3 的 18 个骨架文件需要逐函数迁移
  （每函数独立 PR，bit-equal 验证）。详见各骨架文件顶部 TODO 列表。
- **per-system reads/writes 校验**：当前是 whole-tick 维度；future iteration
  在 SUS 内部加 hook 让每个 system 单独校验。
- **DCSystemScheduler main.gd 接入**：use_dc_system_scheduler flag 已就位，
  实际把 main 切到新调度器在 D.3 main.gd 拆分时一并完成。
- **map_generator.gd → DCSystem 化的逻辑搬迁**：3 大型 system（climate / weather /
  ocean）目前是 wrapper（内部仍 forward 到 SusJob）；后续 PR 把内部 SusJob
  字段 inline 到 DCSystem 并删除冗余的 25 行 _comp_cell_* cache。

### 4.2 阶段 II / III / IV（明确不在范围内）

- 阶段 II（数据所有权下移）：HexCell 改只读 facade、砍 flush_soa_to_cells —
  框架硬化 Phase A.2 的 ViewAdapter 已经为这一步铺平了路（数据侧切换对 UI
  透明），但实际切换不在本规划。
- 阶段 III（serialize / deserialize）：DCWorld.serialize() 按 schema 自动遍历。
- 阶段 IV（SIMD / 线程化）：触发条件 charter §3.1 / §3.2，**绝不主动启动**。

---

## 5. 文档导航树

```
docs/
├── DOTS review.md ........................... 现状评估 + 7 条架构债（背景）
├── dots-migration-roadmap.md ................ 5 阶段路线图 + 单模块 7 步 SOP（蓝图）
├── dots-framework-status.md ................. 本文档（onboarding 速查）
├── module-ownership-map.md .................. 拆分后每模块 owner + reads/writes
├── dots-component-schema.md ................. ComponentSchema (A1) 使用手册
├── dots-view-adapter-guide.md ............... ViewAdapter (B2) 维护者手册
├── dots-system-design.md .................... DCSystem + DCSystemScheduler 设计文档
├── performance-charter.md ................... 硬性宪章（铁律 / 反模式 / SIMD 触发）
├── cpp-gdscript-best-practices.md ........... C++ pass 操作手册（含全局架构图）
├── dots-experiment-report.md ................ A1/A2/B0 实验报告（决策依据）
└── cpp-async-experiment-report.md ........... D-async 实验报告
```

读顺序建议：
1. **第一天**：本文档（dots-framework-status.md）+ module-ownership-map.md
2. **第二天**：performance-charter.md + dots-system-design.md
3. **要写新模块**：dots-migration-roadmap.md §5 + tools/migration_harness/README.md
4. **要 C++ 化**：performance-charter.md §12 + cpp-gdscript-best-practices.md

---

## 6. 当前可立刻动手的事

完成框架硬化（A/B/C/D Phase）后，你可以立刻开干：

- ✅ **任意新模块（economy / unit / AI / pollution / …）按 SOP 迁移**：从 template_bench.gd 拷一份开始，遵守 7 步 SOP，一周内可完成 GDScript 路径
- ✅ **巨石模块逐函数搬到骨架**：B.2 / D.1 / D.2 / D.3 的骨架文件顶部都有详细 TODO，按优先级一个个搬，每个 PR 30 分钟验证
- ✅ **加新 feature flag**：feature_flags.gd FLAGS 表加一行 + ClimateProfile @export 字段
- ✅ **加新 cell 字段**：component_schema.gd 加一行 + 跑 codegen + rebuild gdext

---

## 7. DOTS 化收官状态（dots-monolith-split 计划，2026-05-14）

完整计划详见 `.codebuddy/plan/dots-monolith-split/{requirements,task-item}.md`。

**已完成**：
- ✅ Stage 1（任务 1–6）：基线建立、hot-path 直写消灭、flag 默认全开、scheduler 接管、HexCell facade 启用
- ✅ §1.1 weather sub-module 抽出第一批：`_tick_cyclone_wake` + fronts 推进段（含 F.6 C++ 快路径 + GDScript fallback + reap）从 weather_system.gd 搬到 [`scripts/weather/front_advect.gd`](../Project/project-keynes/scripts/weather/front_advect.gd)。weather_system.gd 行数 3186 → 3038。
- ✅ §1.2 骨架 wire-up：weather_system 实例化 `DCWeatherFieldSolver` 占位，下个子 PR 起逐函数搬迁 ~1500 行 field-solver 主体。
- ✅ §5 渲染/UI cell 直读迁移：经审计 `hex_renderer.gd / data_overlay_baker.gd / info_panel_controller.gd` 已全面 `DCViewAdapter.Cell` 化，残留 `cell.<field>` 均为 non-schema 字段（`passable_sea / vegetation_vitality / slp / wind_stress_curl / ocean_psi / ...`）或 adapter == null fallback；不存在 schema-mirrored 字段直读。
- ✅ §6 Flag 注册收口：`climate_profile.gd` 全部 20 个 `@export var use_*: bool` 已 1:1 注册到 `feature_flags.gd::FLAGS`，`use_dc_system_scheduler / use_hexcell_facade / 7 个 use_gdext_*` 默认 true。
- ✅ §7 静态门禁脚本：[`tests/dots_completion/dots_completion_gate.gd`](../Project/project-keynes/tests/dots_completion/dots_completion_gate.gd)。Headless 跑法：`godot --headless --script tests/dots_completion/dots_completion_gate.gd --quit`。

**剩余工程项（按风险递增）**：

| Plan ID | 巨石 | 当前行数 | 目标 | 待迁出 | 估计 sub-PR 数 |
|---|---|---|---|---|---|
| §1.2-1.4 | weather_system.gd | 3038 | ≤ 400 | ~2638 | 5–8（每个 ≤ 300 行 + bit-equal A/B） |
| §2.1-2.4 | map_generator.gd | 6747 | ≤ 1500 | ~5247 | 8–12 |
| §3.1-3.2 | map_baker.gd | 3028 | ≤ 800 | ~2228 | 5–7 |
| §4 | main.gd | 2126 | ≤ 400 | ~1726 | 5 |

**每个剩余 sub-PR 必须**：
1. 范围 ≤ 300 行（含 owner 字段访问注入 / 调用点重写）
2. 100 tick SAME_SOURCE A/B：旧路径 vs 新路径数值 bit-equal（atlas sha256 一致 / `mean_diff(field) < 0.01`）
3. 跑 `dots_completion_gate.gd` 验证未引入新失败项
4. commit message 引用 `dots-monolith-split §X.Y` 作为追溯锚点

**HexCell 21 字段 setter 锁定（§6 第二项）状态**：当前 hot path 仍有 50 处 `cell.<field> = v` 命中（map_generator.gd 45 + weather_system.gd 5）。这些**经 facade 透传走 SoA**，非"直写 SoA bypass"。若要按计划改为 `assert(false, "facade write in hot path is forbidden")`，需先把所有 hot path 改为直接 `world.write_f32(cid, idx, v)`，破坏 `cell.temperature = v` 的源代码可读性设计。本项保留为后续设计权衡决策点，不在 monolith-split 计划范围内强制收口。

---

**END of dots-framework-status.md.**
