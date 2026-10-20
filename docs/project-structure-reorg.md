# 项目结构整理记录（2026-10-20）

针对「目录杂乱、测试全平铺、tmp 到处都是、不知道什么是什么」的一次结构性整理。

---

## 一、诊断结论

### 1.1 结构其实是好的部分

| 目录 | 规模 | 组织方式 | 判断 |
|---|---|---|---|
| `scripts/` | 768 文件 / 22 子目录 | 按领域分（ui 133、data 35、rendering 30、geography 17…） | **合理，未动** |
| `data/` | 772 文件 / 18 子目录 | `economy/` 493 个 `.tres` 又细分 7 个子目录 | **合理，未动** |
| `assets/` | 368 文件 | 按 audio/fonts/icons/textures/themes/ui/vfx 分 | **合理，未动** |
| `shaders/` | 151 文件 | 按 bake/compute/include/ui 分 | **合理，未动** |

### 1.2 真正乱的三处

**A. `tests/` 401 个 `.gd` 全部平铺在顶层**，没有一个子目录；前缀碎成 **80 多种**
（runtime 39、technology 28、economy 22…后面全是 1–5 个的碎片）。
但其中 **320 个是正规 `_test.gd` 回归测试**，不是垃圾——问题是找不到。

**B. `tmp/` 有 90 个顶层目录、1649 个文件（445 MB）**，几乎全是 `*_qa` 截图。

**C. 根目录散着** 13 个 Godot 编辑器日志、`test_out.log` / `test_err.log`、
一个**没有任何引用**的 `tmp_inspect_pkfg.gd`（+`.uid`）、3 个 `_tmp_*.tscn` 探针场景。
**这些日志和孤立脚本都被 Git 跟踪**——纯垃圾却进了版本库。

---

## 二、执行内容

### 2.1 删除（451 个文件，全部经核对）

| 类别 | 数量 | 处理方式 |
|---|---|---|
| Godot 编辑器日志 `Godot_v4.6.2-stable_win64.*.log` | 13 | `git rm` |
| `test_out.log` / `test_err.log` | 2 | `git rm` |
| 根目录孤立脚本 `tmp_inspect_pkfg.gd` + `.uid` | 2 | `git rm`（全项目零引用） |
| 一次性探针（10 个 `.gd` + `.uid` + 2 个 `.tscn`） | 22 | `git rm` |
| 孤儿 `.uid`（对应 `.gd` 早已不存在） | 6 | `git rm` |
| `tmp/*_qa/` 的 QA 截图 | 406 | 先物理删，再 `git add -u` 暂存 |

> 探针筛选依据：**30 天内无修改**且名字含 `tmp_`/`_tmp_`。
> 昨天/今天还在改的 `effect_pod_capability_probe.gd`、`ideology_phase1_probe.gd` 一律保留。
> 被生产代码挂钩的 `colonization_probe.gd`、`family_economy_probe.gd` 也保留
> （`game_flow_service.gd` 的 `PK_COLONIZATION_PROBE` / `PK_FAMILY_PROBE` 依赖它们）。

### 2.2 `tests/` 重构：401 → 15 个领域子目录

分类依据是**被测子系统**，规则见 `tests/README.md`。结果：

| 目录 | 数量 | 目录 | 数量 |
|---|---|---|---|
| `economy/` | 65 | `family/` | 16 |
| `runtime/` | 61 | `effect/` | 15 |
| `world/` | 48 | `qa/` | 10 |
| `ui/` | 42 | `building/` | 10 |
| `technology/` | 34 | `trigger/` | 7 |
| `game/` | 28 | `audio/` | 3 |
| `ideology/` | 18 | `dots_completion/` | 2（原有） |
| `country/` | 17 | | |
| `probes/` | 16 | **顶层剩余** | **0** |

分类后 **`misc/` 归零**——没有"不知道该放哪"的文件。

### 2.3 引用同步（这是最容易出错的一步）

| 项 | 数量 | 处理 |
|---|---|---|
| `.gd` / `.tscn` / `.tres` 内的 `res://tests/<name>.gd` | 116 条，分布在 110 文件 | 按完整路径精确替换为 `res://tests/<group>/<name>.gd` |
| `.md` 文档里的 `tests/<name>.gd` 示例命令 | 28 条，分布在 9 个文档 | 同步改写 |
| `.tscn` 测试场景 | 10 个 | 跟随对应 `.gd` 移动到同组 |
| `game_flow_service.gd` 的 headless 钩子路径 | 4 条 | 随批量替换更新 |
| `.uid` 伴随文件 | 389 个 | 与 `.gd` 一起移动 |

---

## 三、验证

1. **引用存在性全量检查**：提取全项目所有 `res://tests/...gd` 引用（66 条唯一路径），
   逐条验证目标文件存在 → **0 条失效**。
2. **删除清单逐条核对**：451 个删除全部对应预期目标，无源码误删。
3. **Git 重命名识别**：`git add -A` 后 765 个文件被识别为 **R（rename）**，
   历史可追溯，不是"删除+新增"。
4. **继承链抽查**：`economy_preview_basis_parity_test.gd` → `extends` 的父类在新路径下存在。
5. **孤儿 `.uid`**：剩余 9 个 `.gd` 无 `.uid`，核实为**新增文件本就没有**（非本次移动导致），
   Godot 下次导入会自动生成。

---

## 四、当前状态

| 位置 | 整理前 | 整理后 |
|---|---|---|
| `Project.Keynes/tmp/` | 1502 MB | **30 MB** |
| `Project/project-keynes/tmp/` | 445 MB | **11 MB**（67 项，含 15 个探针脚本） |
| `Project/project-keynes/` 根目录 | 13 个日志 + 孤立脚本 + 临时目录 | **只剩标准目录与 `project.godot`** |
| `tests/` 顶层 | 401 个 `.gd` + 10 个 `.tscn` 平铺 | **0 个文件，只有 16 个子目录** |

---

## 五、仍待处理（未在本次范围）

| 项 | 说明 | 建议 |
|---|---|---|
| `tmp/` 下 50 个被跟踪的探针脚本 | `*_probe.gd` / `*_audit.gd` / `*_replay.gd` 等在 `tmp/` 却被 Git 跟踪 | 迁到 `tests/probes/`，或 `git rm --cached` 后加忽略 |
| `.venv-build/`（2117 文件被跟踪） | 整个 Python venv 进了版本库 | `git rm -r --cached` + 加 `.gitignore` |
| `Project/perf-validation/tmp/` 129 MB | 542 个被跟踪文件（含 19 个 `bench_*.gd`） | 需单独评估 |
| 274 个 dll/pdb 被跟踪 | `.git` 反复膨胀的根因 | 见 `project-cleanup-audit.md` 第七节 |
| `_debug_atlas/`、`test_output/`、`materials/` | 各 1–2 个文件的小目录 | 确认用途后归入 `assets/` |

---

## 六、给未来的一条规矩

**新增测试直接放进对应领域子目录，不要放 `tests/` 顶层。**
移动任何测试时必须同步四处：项目内 `res://tests/...` 引用、`docs/` 里的示例命令、
`game_flow_service.gd` 的 headless runner 映射、以及 `.uid` 伴随文件。
