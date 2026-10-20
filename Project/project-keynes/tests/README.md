# tests/

本目录按**领域**分目录。**不要再把测试平铺在顶层**——顶层只留子目录。

## 目录索引

| 目录 | 文件数 | 覆盖范围 |
|---|---|---|
| `runtime/` | 61 | 运行时权威、原生（C++）边界、POD 快照、DOTS、阶段顺序与位相等 |
| `economy/` | 65 | 经济结算、贸易、资源、价格、就业、建造与生产、税收 |
| `world/` | 48 | 地形生成、气候、天气、生物群系、植被、河流/海洋、地图 |
| `ui/` | 42 | 视图模型、面板、单位检查器、年度报告、视觉与截图类断言 |
| `technology/` | 34 | 科技树、研究队列、时代推进、科技目录与绑定 |
| `game/` | 28 | 游戏流程、玩家控制器、存档、加载、主菜单、headless 入口 |
| `ideology/` | 18 | 理念系统、理念卡、效果与协同 |
| `country/` | 17 | 国家核心、边界、殖民与定居 |
| `probes/` | 16 | 一次性探针与临时脚本（`tmp_*` / `_tmp_*`），允许随意增删 |
| `family/` | 16 | 家族、生育、世代与家族工作区 |
| `effect/` | 15 | 效果系统、修正器、指标、目标选择器 |
| `qa/` | 10 | 截图对比与视觉冒烟（`*_screenshot_qa` / `*_visual_smoke`） |
| `building/` | 10 | 建筑定义、建筑经济与图集 |
| `trigger/` | 7 | 触发器条件、聚合、重放 |
| `audio/` | 3 | FMOD 事件、音频演示与冒烟测试 |
| `dots_completion/` | 2 | DOTS 完成度门禁与基线记录 |

> 分层依据：4xx 个测试原先全部平铺在顶层、前缀碎成 80 多种，导致无法定位。
> 现按**被测子系统**归组，同组内再靠文件名前缀区分具体功能点。

## 怎么运行

单个测试，headless 跑：

```bash
godot --headless -s Project/project-keynes/tests/economy/baker_atlas_section_verdict_test.gd
```

带渲染的截图类测试（`qa/` 与部分 `ui/`）：

```bash
godot --path Project/project-keynes res://tests/ui/annual_report_runtime_test.tscn
```

部分探针通过环境变量挂载，由 `scripts/game/game_flow_service.gd` 的
`_attach_headless_runner()` 注册（例如 `PK_FAMILY_PROBE` → `family/`、
`PK_COLONIZATION_PROBE` → `country/`）。移动这类文件时**必须同步更新该处路径**。

## 命名约定

| 后缀/前缀 | 含义 | 生命周期 |
|---|---|---|
| `*_test.gd` | 回归测试，应当长期保持通过 | 永久 |
| `*_probe.gd` | 探针，验证某个假设后即可废弃 | 中期 |
| `*_screenshot_qa.gd` | 截图对比，需要渲染环境 | 永久 |
| `*_visual_smoke.gd` | 视觉冒烟 | 永久 |
| `*_bench.gd` | 性能基准，结果不进断言 | 中期 |
| `tmp_*` / `_tmp_*` | 一次性脚本 | 短期，用完即删 |

## 新增测试的规矩

1. **按被测系统放进对应子目录**，不要放顶层。
2. 文件名沿用 `<子系统>_<功能点>_test.gd`，保证同目录内可读。
3. 移动或重命名测试时，务必同步：
   - 全项目的 `res://tests/...` 引用（`.gd` / `.tscn` / `.tres`）
   - `docs/` 与资产 README 里的示例命令
   - 上述 `game_flow_service.gd` 的 headless runner 映射
4. `.uid` 文件必须跟 `.gd` 一起移动，否则引用会失效。

## 历史

2026-10-20 由平铺改为分领域组织。同批清理了：13 个 Godot 编辑器日志、
根目录无引用的 `tmp_inspect_pkfg.gd`、10 个两个月未改动的临时探针、
6 个孤儿 `.uid`。
