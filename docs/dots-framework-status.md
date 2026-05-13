# Project.Keynes — DOTS 框架现状速查（onboarding 必读）

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
      └─ F.4/F.6 2 个 stub（return -1.0；待后续 PR 按 F.1-F.3 模板填入）

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

**END of dots-framework-status.md.**
