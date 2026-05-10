# Project.Keynes

一个基于 Godot 4.6 的程序化六边形世界模拟。

## 当前进度

| 模块 | 状态 |
|---|---|
| `geography` 地理与世界基础 | **v1 冻结** |
| `weather` 天气模拟 | **Phase 0~3 v9d 完工**（待启动 Phase 4：日出金边/伪体积感） |
| `economy` 经济 | **在建**（占位 + 边界设计） |
| `civ` 文明 / `unit` 单位 / `events` 事件 | 未规划 |

## 模块布局

源码全部在 `Project/project-keynes/scripts/`：

```
scripts/
├── main.gd                   # 入口（main.tscn 挂）
├── geography/                # 地图 / hex / 类型枚举 / 世界时钟
│   └── MODULE.md             # 对外只读字段契约 + 公共 API
├── weather/                  # 云场 / 锋面 / 风带 / 积雪
│   └── MODULE.md             # Phase 调参 rationale + 调用约束
├── economy/                  # 经济模块（待开工）
│   └── MODULE.md             # 边界声明 + MVP 草案
├── data/                     # *.tres 资源对应的 GDScript（profile + registry）
├── rendering/                # MapBaker / HexRenderer / WeatherLayer / PhysicalCirculationSolver
├── simulation/sus/           # Sliced Update Scheduler + Jobs
└── ui/                       # 调试控制台 / 图例
```

> **重要**：`data/`、`rendering/`、`simulation/`、`ui/` 路径被 `.tres` / `main.tscn` 硬绑，不要在 Godot 编辑器外移动它们。

## 新增模块开工流程

1. 在 `scripts/<module>/` 下建目录 + `MODULE.md`
2. `MODULE.md` 必须写：作用范围、依赖出向、对外公共类、不要直接调的内部方法
3. 实现时优先用 `class_name` 全局符号；只有 Godot 报"全局类未拾取"时才退回 `preload("res://scripts/<module>/...")`
4. 注册到 `MapGenerator` 或 SUS 时，用单向 wire-up（构造期注入），避免循环依赖

## 数据驱动

地形/植被/天气/世界预设全部是 `.tres`，见 `Project/project-keynes/data/README.md`。

## 历史决策

- 天气系统 Phase 0~3 的多轮调参备忘见 `~/.workbuddy/memory/2026-05-*.md`
- 早期重构计划在 `.codebuddy/plan/`

## 跑起来

打开 `Project/project-keynes/` 作为 Godot 4.6 项目，主场景 `scenes/main.tscn`。
