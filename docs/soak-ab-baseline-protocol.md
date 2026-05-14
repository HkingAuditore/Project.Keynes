# Block A 写路径下移 — SoakAB 验收基线 SOP

> 路线图：[`docs/dots-master-execution-handbook.md`](dots-master-execution-handbook.md) Block A — Phase 2 数据所有权下移
> Plan：`.codebuddy/plan/dots-block-a-write-path-sinking/`
> Runner 实体：[`Project/project-keynes/scripts/tools/dots_soak_ab_runner.gd`](../Project/project-keynes/scripts/tools/dots_soak_ab_runner.gd)

本文档约束 **每个 PR 启动前 / 合并前** 录制 SoakAB 报告并归档的标准流程，确保红线可追溯、回归可定位。

---

## 1. Runner 速查

| 模式 | 触发 | 通过条件 | 用途 |
|---|---|---|---|
| **SAME_SOURCE** | `F3` | `verdict: PASS ✓`（max_field mean_diff ≤ 1e-4 / scalar < 0.05 / long-term < 0.01） | storage 同源可重复性，每 PR 必跑 |
| **VS_LEGACY** | `Shift+F3` | 各字段 mean_diff 在手册 §3.x 容差内 | DataCore vs legacy 业务对比，2.1.x 系列必跑 |
| **FLAG_PROFILE** | 代码调用 `start_flag_profile()` | 同 SAME_SOURCE | flag 翻转前后等价性，PR-passA-unblock 用 |

输出：

- **stdout**：完整报告（Top-15 字段差异表）
- **持久化**：`user://soak/last_report.txt`（每次覆盖）
- **TSV**：`user://soak/{same\|vsleg\|flags}_{A,B}_<timestamp>.tsv`

`user://` 在 macOS 实际路径：

```
~/Library/Application Support/Godot/app_userdata/ProjectKeynes/soak/
```

> 注意：目录名是 `ProjectKeynes`（无空格），不是 `Project Keynes`。

---

## 2. 标准跑法（每 PR 三次）

### 2.1 录制时机

每个 PR 必须录三份报告：

1. **before**：基于 PR 起点 commit（merge base），未做任何改造时
2. **after-impl**：改造完代码、本地编辑器一跑通就录
3. **after-soak**：CI（或本机）跑过 SAME_SOURCE 三次都 PASS 后的最后一次

`before` 与 `after-soak` 的 max_mean_diff 必须**持平或下降**；上升即视为引入回归。

### 2.2 操作步骤（编辑器内，~3 秒/次）

1. 在 Godot 4.6 编辑器打开 `Project/project-keynes/`
2. F5 运行（main scene 已配 `--use_data_core --use_data_core_weather`）
3. 等控制台出现 `[DataCore] flags after CLI: use_data_core=true ...` + 地图渲染完
4. **将速度档切到 x20**（30 tick × 2 phase ≈ 3 秒）
5. 按 **F3**（SAME_SOURCE）或 **Shift+F3**（VS_LEGACY）
6. 等控制台打印 `=================== DCSoakABRunner Report ===================`
7. 复制 `user://soak/last_report.txt` 到 `.workbuddy/baselines/<pr-id>/<phase>.txt`，文件命名见下文 §3

### 2.3 1000-tick 长期 soak（PR-2.1.1 / PR-2.2 / PR-2.3 必跑）

部分 PR（手册 §3 标注"长期均值"）需要 1000-tick：在编辑器内打开 Debug Console（` 键 / F1），输入：

```gdscript
DCSoakABRunner.instance = DCSoakABRunner.new()
DCSoakABRunner.instance.start(get_tree().root.get_node("Main"), 1000, DCSoakABRunner.Mode.SAME_SOURCE)
```

x20 速度下约 100 秒。

---

## 3. baseline 文件归档约定

目录布局：

```
.workbuddy/baselines/
├── README.md                                    # 表格索引（每完成一个 PR 加一行）
├── master-2026-05-15/                           # Prep-0 的 master 基线
│   ├── same-source-30tick.txt                   # 复制自 user://soak/last_report.txt
│   ├── same-source-30tick.A.tsv                 # 可选，争议时回看
│   ├── same-source-30tick.B.tsv
│   └── notes.md                                 # 跑的环境（commit / dylib mtime / OS / Godot 版本）
├── pr-passa-unblock/
│   ├── before.txt
│   ├── after-impl.txt
│   ├── after-soak.txt
│   └── notes.md
├── pr-2-1-1-climate-pass-a/
│   └── ...
... 每 PR 一个子目录
```

`notes.md` 模板：

```markdown
## Run env

- commit: <git rev-parse HEAD>
- branch: <git branch --show-current>
- dylib mtime: <ls -l Project/project-keynes/addons/dots_ext/bin/macos/libdots_ext.macos.template_debug.arm64.dylib>
- godot: 4.6.2 stable
- macOS: <sw_vers -productVersion>

## Result summary

- mode: SAME_SOURCE
- n_ticks: 30
- verdict: PASS / FAIL
- max_field: <字段名>
- max_mean_diff: <数值>
- worst_scalar: <数值> / 阈值 0.05
- worst_long: <数值> / 阈值 0.01
```

---

## 4. 红线汇总（手册 §7.1 / §3.x）

| PR | 必跑模式 | 关键阈值 |
|---|---|---|
| PR-passA-unblock | SAME_SOURCE + VS_LEGACY | SAME_SOURCE PASS；VS_LEGACY cell.temp mean_diff ≤ 0.05 |
| PR-2.1.1 Pass-A | SAME_SOURCE 30 + 1000 tick | **长期均值字段 mean_diff ≤ 0.005**（temp_30d / temp_365d / temp_anomaly） |
| PR-2.1.2 Pass-B | SAME_SOURCE | cell.moisture mean_diff ≤ 0.05 |
| PR-2.1.3a/b ocean | SAME_SOURCE | scalar < 0.05 / long-term < 0.01 |
| PR-2.1.4 sea_ice | SAME_SOURCE | sea_ice_frac mean_diff ≤ 0.05 |
| PR-2.1.6 weather | SAME_SOURCE + VS_LEGACY | VS_LEGACY weather_type mean_diff 应**降低** |
| PR-2.2 删 flush | SAME_SOURCE 30 + 1000 tick | **bit-equal**（max_mean_diff < 1e-6） |
| PR-2.3 facade | §7.1 全套 | scalar < 0.01 / long-term < 0.005 |

---

## 5. 红线不过的标准回滚

```bash
# 1. revert PR commit
git revert <pr-commit-hash>

# 2. 重跑 SAME_SOURCE 三次确认稳定
#    （手动 F3 三次，三次都 PASS 视为干净）

# 3. 在 dots-framework-status.md 加一行 incident log
#    格式：YYYY-MM-DD | PR-x.y.z | <field>=<diff> > <threshold> | reverted

# 4. 如有必要，rebase 当前 plan 重新出 PR
```

---

## 6. CI 自动化（可选 / 后续补丁）

当前 SoakAB 仅有编辑器 F3 入口。如需 CI 自动跑 A/B 一次完成，可加 CLI flag `--soak-ab=N` 到 `main.gd:1686` 的命令行解析处（≤30 行补丁），在 `_generator` 就绪后直接 `DCSoakABRunner.new().start(self, N, ...)` 并在 `completed` 信号 `quit()`。**本 plan 不强制要求该补丁**——手动 F3 已够。
