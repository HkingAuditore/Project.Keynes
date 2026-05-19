---
name: cpp-atlas-encode-stage-g-acceptance
overview: 阶段 G 验收：1) 写 tests/cpp_atlas_encode_bitequal_test.gd（SceneTree runner 风格，3 场景 byte-by-byte 比对 GDScript / C++ 路径）；2) 加 baker 段 4 档时延采集 driver 并复用已就位的 evaluate_baker_atlas_section 出 AB 报告（verdict 代码无需改动）。
todos:
  - id: grounding
    content: 使用 [skill:civ-grounded-development] + [subagent:code-explorer] 对 baker 内部字段、SUS job_id、verdict 公开 API 出 grounding 笔记
    status: completed
  - id: bitequal-test
    content: 写 tests/cpp_atlas_encode_bitequal_test.gd（SceneTree-style，3 场景 × 4 atlas byte-by-byte，含 dll 缺失优雅 skip）
    status: completed
    dependencies:
      - grounding
  - id: perf-driver
    content: 写 scripts/data_core/baker_atlas_section_perf_driver.gd（4 档轮换 + 时延采样 + markdown 报告）
    status: completed
    dependencies:
      - grounding
  - id: run-validate
    content: 用户跑单测 + driver，产出 AB 报告并贴回数字
    status: completed
    dependencies:
      - bitequal-test
      - perf-driver
  - id: plan-finalize
    content: 更新 plan.md 阶段 G 收尾段：状态固化 + AB 报告路径 + next_bottleneck 输入
    status: completed
    dependencies:
      - run-validate
---

## 阶段 G 验收：bit-equal 单测 + 4 档 perf AB 报告

### 背景

plan/dirty-push-atlas-encode 阶段 E/F 的 C++ atlas-encode 4 个 pass（dynamic_cell / ecology_visual / dyn_smooth / ice_state）已落地，dll 已 ship（debug 924672 / release 856064 bytes）。GDScript fast-path 分支 + CSR 打包 helper 已写入 baker，flag `cpp_atlas_encode_enabled` 默认 false，待验收启用。

### 核心交付

- **bit-equal 正确性单测**：覆盖 3 个关键场景（cache_invalid 首帧 / cache_valid 增量帧 / ecology transition_age 衰减一帧），byte-by-byte 比对 GDScript 与 C++ 两条路径在同一 dirty 集下输出的 4 张 atlas buffer。
- **4 档 perf 采集 driver**：对接现有 `DCDotsFinalPushPerfVerdict.evaluate_baker_atlas_section` 的 4 档（legacy / mask_gd / mask_gd_full / mask_cpp），由 dev-only 调试入口在同一存档下顺序切 flag 跑 N tick，把 baker 段 ms 灌入 verdict，输出 markdown AB 报告。
- **plan.md 收尾**：阶段 G 状态固化、AB 报告归档路径、回滚指引、下一轮 next-bottleneck 输入。

### 验收门槛

1. **bit-equal**：4 张 atlas buffer 在 3 个场景下逐字节相等（PackedByteArray 长度 + 内容），任一字节差异即 FAIL。
2. **perf**：mask_gd p95 ≤ legacy × 0.5；mask_cpp p95 ≤ mask_gd × 0.5；任一档不得比 legacy 慢 10% 以上（已由 verdict 内置门槛把关）。
3. **回退安全**：单测在 dll 未编 / flag 关闭时优雅 skip 而非 crash；perf driver 跑完自动恢复 flag 原值。

### 不动点

- 不引入 GUT 框架（项目走 SceneTree-style runner，与现有 8 个 _test.gd 同形）
- 不改 verdict 公开 API（`evaluate_baker_atlas_section` / `format_baker_atlas_section_lines` 保持现签名）
- 不改 baker chunk_step / cpp encode_* method 签名
- master 分支默认仍 `cpp_atlas_encode_enabled = false`

## Tech Stack

- Godot 4.6 GDScript（SceneTree-style headless test runner）
- 已 ship 的 GDExtension（`dots_ext.windows.template_debug.x86_64.dll`）
- 已 ship 的 `DCDotsFinalPushPerfVerdict.evaluate_baker_atlas_section`（4 档对照逻辑层）

## Implementation Approach

### 1. bit-equal 单测策略

**核心思路**：把 4 张 atlas baker 的 chunk_step 改造成可"无副作用 dump"的形态——单测构造小型 mock world（≥ 32 cells，覆盖海/陆/冰/不同 vegetation），调用 baker 完整跑一次拿到 buffer 副本，然后 toggle `cpp_atlas_encode_enabled` 再跑一次，逐字节对比。

**关键技术决策**：

- **不 mock baker 内部状态**：直接复用 `MapBaker` + 真实 `DCWorld` + 真实 `DCWorldExt`（小地图 ≤ 64 cells 跑得动），避免 mock 偏离真实路径。这样测的就是生产代码本身，零等价性风险。
- **buffer 抓取点**：每个 chunk_step 完成后，atlas_buffer 已写入 `_pending_*_buffer`（baker 现有字段），单测调用 baker 公开方法或 helper 拿 `bytes.duplicate()` 即可，不入侵 baker 内部。如果现有公开口子不够，加 1-2 个 dev-only getter（不影响生产路径）。
- **状态字典对齐**：每个场景跑前手动把 `_last_*_sigs` / prev_veg / prev_vitality / prev_transition 重置到已知态，保证 GDScript 与 C++ 两次运行的入参完全一致。
- **优雅 skip**：单测开头检查 `DCWorldExt.has_method("encode_dynamic_cell_atlas")` + `cpp_atlas_encode_enabled` 可写——任一缺失则 print "SKIP: dll/flag missing" + `quit(0)`，CI 视为通过。

**3 个场景**：

- **场景 1 (cache_invalid 首帧)**：清空所有 sig cache，全部 N cell 标 dirty，跑两次（GD/cpp）比对 4 张 buffer。
- **场景 2 (cache_valid 增量帧)**：先用 GDScript 路径跑一次填好 cache，然后改动 5 个 cell 的 temperature/moisture，再分别走两条路径，比对增量帧产生的 buffer。
- **场景 3 (ecology transition_age)**：构造一组 prev_veg ≠ current_veg 的 cell，验证两条路径的 transition_age 衰减/重置完全一致（重点比对 `new_transition` 字典 + ecology_visual_atlas_buffer 的 G/B 通道）。

### 2. 4 档 perf 采集 driver

**核心思路**：写一个 dev-only `DCDotsBakerAtlasSectionPerfDriver`（class_name），由调试快捷键或 main scene 启动时触发；driver 顺序切 flag 跑 N tick（默认 N=200，per-档），收 `chunk_step` 段时延到 4 个 `Array[float]`，最后调 `evaluate_baker_atlas_section` + `format_baker_atlas_section_lines` 打日志 + 写 markdown。

**关键技术决策**：

- **采样口子复用 SUS scheduler**：4 个 chunk_step 段如果已经有 SUS job stats（`enum_atlas_upload` / `dynamic_visual_atlas_upload` 之类），直接读 `_stats[job_id].samples`，否则在 driver 里手动 `Time.get_ticks_usec()` 包裹 baker.tick 调用累计 ms。优先复用，避免双采样源不一致。
- **flag 切换**：driver 持有 `ClimateProfile` 引用，按 `[(dirty=false, cpp=false), (dirty=true, cpp=false), (dirty=true, cpp=false, force_full=true), (dirty=true, cpp=true)]` 4 档轮换，每档跑前 reset baker `_last_*_sigs` 缓存到等效初始态以保证 dirty 工况可复现。
- **markdown 报告**：写到 `Project/project-keynes/.codebuddy/perf-reports/dirty-push-atlas-encode_AB_<timestamp>.md`，内容含 4 档 avg/p50/p95/p99 + reductions + verdict PASS/FAIL + 测试环境（cell_count / soak ticks / cpu / godot version）。
- **soak 长度**：默认 200 tick × 4 档 = 800 tick，按 30fps 约 30s 内完成，可在调试 HUD 显示进度。

### 3. plan.md 收尾

- 把当前的「阶段 E/F 代码就绪 → 等编译」更新为「阶段 E/F/G 全部 ship」
- 追加 AB 报告路径占位 + 实际跑完后的关键数字
- 追加 next-bottleneck（取 `verdict.next_bottleneck`）作为下一轮 plan 的输入

## Implementation Notes

### Performance

- 单测仅跑小地图（≤ 64 cells），全部 3 个场景预计 < 1s 完成；不引入额外热路径开销。
- driver 仅在 dev 模式下加载，runtime 零成本（按 `OS.is_debug_build()` 或显式 flag 守卫）。
- 状态字典 reset 用 `clear()` 而非 `assign({})`，避免无意义对象分配。

### Logging

- 复用现有 `print` / `print_rich` 风格，前缀 `[plan/dirty-push-atlas-encode/G]`，与现有阶段日志同形。
- bit-equal 失败时打印 first diff offset + 上下文 16 字节（`hex(buf[max(0,off-8):off+8])`），方便定位。
- 不打印整 buffer（避免 N×n_pix×4 字节日志炸弹）。

### Blast Radius

- 仅新增 1 个测试文件 + 1 个 dev-only driver 脚本 + 现有 plan.md 末尾追加，不改任何生产路径。
- 单测的 baker dev-only getter 若必须新增，附 `## DEV-ONLY: bit-equal test bridge` 注释 + 默认空实现保护。
- driver 写文件用 `FileAccess.WRITE` + 异常守护，写不出不影响游戏。

## Architecture Design

```mermaid
flowchart LR
  subgraph 测试层
    T[cpp_atlas_encode_bitequal_test.gd<br/>SceneTree headless]
    P[baker_atlas_section_perf_driver.gd<br/>dev-only]
  end

  subgraph 已 ship 生产代码
    B[map_baker.gd<br/>4 chunk_step + cpp fast-path]
    V[dots_final_push_perf_verdict.gd<br/>evaluate_baker_atlas_section]
    E[world_ext.{h,cpp}<br/>encode_* 4 method]
    F[ClimateProfile<br/>cpp_atlas_encode_enabled]
  end

  T -->|toggle flag<br/>跑两次比 byte| B
  T -->|skip if missing| E
  P -->|顺序切 4 档<br/>采样 ms| B
  P --> V
  P -->|输出 md| R[(perf-reports/<br/>AB.md)]
  B --> E
  B -.flag.- F
```

### Module 划分

- **测试模块**：`tests/cpp_atlas_encode_bitequal_test.gd`（~250 行）
- **driver 模块**：`scripts/data_core/baker_atlas_section_perf_driver.gd`（~200 行）
- **plan 文档**：现有 plan.md 末尾追加 ~40 行
- 不改：verdict / baker / world_ext / ClimateProfile / FeatureFlags

## Directory Structure

```
Project.Keynes/
├── Project/project-keynes/
│   ├── tests/
│   │   └── cpp_atlas_encode_bitequal_test.gd  # [NEW] SceneTree-style 单测；3 场景 × 4 atlas byte-by-byte 对比；构造 mock world (≥32 cells 含海/陆/冰/不同 veg)；toggle cpp_atlas_encode_enabled 跑两次抓 _pending_*_buffer 比对；优雅 skip（dll 缺/flag 缺时 quit(0)）；首字节差异定位（hex 上下文 16 字节）。
│   ├── scripts/data_core/
│   │   └── baker_atlas_section_perf_driver.gd  # [NEW] dev-only 4 档 perf 采集器；class_name DCBakerAtlasSectionPerfDriver；持有 ClimateProfile 引用顺序切 (legacy / mask_gd / mask_gd_full / mask_cpp)；每档跑 N tick（默认 200）收 baker 段 ms；调 DCDotsFinalPushPerfVerdict.evaluate_baker_atlas_section + format_baker_atlas_section_lines；写 markdown 到 .codebuddy/perf-reports/；跑完自动恢复 flag 原值。
│   └── scripts/rendering/
│       └── map_baker.gd  # [MAYBE-MODIFY] 仅在单测必需时加 1-2 个 dev-only getter（例如 get_pending_dynamic_cell_atlas_bytes() : PackedByteArray），附 ## DEV-ONLY 注释；若现有公开口子已够则不动。
└── .codebuddy/plans/cell-dirty-push-and-dots-atlas-bakers_4d679592.md  # [MODIFY] 阶段 E/F/G 状态固化；追加 AB 报告路径 + 关键数字 + next_bottleneck（用于下一轮 plan 输入）。

(运行时产物，由 driver 写出)
└── Project/project-keynes/.codebuddy/perf-reports/
    └── dirty-push-atlas-encode_AB_<YYYYMMDD-HHMMSS>.md  # [RUNTIME] 4 档 AB 报告；含 avg/p50/p95/p99 + reductions + verdict PASS/FAIL + 测试环境元信息。
```

## Key Code Structures

### 单测 skip 守卫（防止 dll 未编时 hard crash）

```
# tests/cpp_atlas_encode_bitequal_test.gd
func _check_prerequisites() -> bool:
    var ext = ClassDB.class_exists("DCWorldExt")
    if not ext:
        print("[SKIP] DCWorldExt class missing — dll not loaded")
        return false
    var w = DCWorldExt.new()
    if not w.has_method("encode_dynamic_cell_atlas"):
        print("[SKIP] encode_dynamic_cell_atlas missing — dll outdated")
        return false
    return true
```

### perf driver 4 档轮换骨架（签名层）

```
# scripts/data_core/baker_atlas_section_perf_driver.gd
class_name DCBakerAtlasSectionPerfDriver extends RefCounted

# 单档配置：(label, dirty_push_enabled, cpp_atlas_encode_enabled, force_full_dirty)
const _PHASES: Array = [
    ["legacy",       false, false, false],
    ["mask_gd",      true,  false, false],
    ["mask_gd_full", true,  false, true ],
    ["mask_cpp",     true,  true,  false],
]

func run(climate_profile, baker, world, ticks_per_phase: int = 200) -> Dictionary
func _collect_baker_section_ms(baker, ticks: int) -> Array  # Array[float]
func _write_markdown_report(verdict: Dictionary, env: Dictionary) -> String  # 返回写出路径
```

## Agent Extensions

### Skill

- **civ-grounded-development**
- Purpose: 强制阶段 G 开工前对 baker chunk_step / DCWorldExt encode_* / verdict.evaluate_baker_atlas_section 三处生产路径做 read-first 对账，确保单测构造的 mock world 与真实 baker 入参等价、driver 切 flag 顺序与 ClimateProfile setter 副作用一致。
- Expected outcome: 产出一份 grounding 笔记列出"复用点（verdict / baker getter / SUS stats）+ 不动点（4 个 method 签名 / flag 默认值 / chunk_step 入口）+ 仅新增点（test + driver）"，与本 plan 的 Directory Structure 逐项对账。

### SubAgent

- **code-explorer**
- Purpose: 在写单测前快速定位 baker 内 `_pending_*_buffer` / `_last_*_sigs` / `_ecology_prev_*` 等内部字段的当前可见性与名字（避免单测里写错字段名），以及 SUS scheduler 是否对 4 个 baker chunk_step 已建 job_id（决定 perf driver 是复用 SUS samples 还是手动计时）。
- Expected outcome: 输出一份字段清单（字段名 + 类型 + 可见性 + 来源行号）+ SUS job_id 清单（命中/未命中），让单测和 driver 直接按事实写代码而非靠假设。