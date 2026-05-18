---
name: android-debug-ui-and-sim-timing
overview: 为安卓测试包前置实现触摸可用的调试入口：把现有键盘快捷调试功能暴露为界面按钮，并把已有 SUS/模拟模块耗时统计显示到调试面板实时监视区。
design:
  styleKeywords:
    - 游戏内调试面板
    - 紧凑触摸控件
    - 深色半透明控制台
    - 实时性能监视
    - 低干扰覆盖层
  fontSystem:
    fontFamily: Noto Sans
    heading:
      size: 18px
      weight: 700
    subheading:
      size: 14px
      weight: 600
    body:
      size: 12px
      weight: 400
  colorSystem:
    primary:
      - "#4EA1FF"
      - "#7CC7FF"
    background:
      - "#20242B"
      - "#2B3038"
      - "#000000"
    text:
      - "#F2F6FF"
      - "#B8C2D6"
    functional:
      - "#7BD88F"
      - "#FFD166"
      - "#FF6B6B"
      - "#9AA4B2"
todos:
  - id: verify-debug-paths
    content: 使用 [skill:civ-grounded-development] 和 [subagent:code-explorer] 复核调试入口与耗时数据源
    status: completed
  - id: add-topbar-buttons
    content: 修改 main.tscn 和 main.gd，增加 Debug、Regen、Fit 触摸按钮
    status: completed
    dependencies:
      - verify-debug-paths
  - id: expose-perf-getters
    content: 在 main.gd 暴露 SUS summary、report、breakdown 只读 getter
    status: completed
    dependencies:
      - verify-debug-paths
  - id: expand-debug-actions
    content: 扩展 debug_console.gd 诊断按钮，复用现有快捷键调试方法
    status: completed
    dependencies:
      - expose-perf-getters
  - id: render-perf-telemetry
    content: 扩展 debug_console.gd Telemetry，显示各模拟模块耗时与最大瓶颈
    status: completed
    dependencies:
      - expose-perf-getters
  - id: validate-mobile-ui
    content: 验证触摸交互、控制台滚动、暂停倍速和性能显示不回归
    status: completed
    dependencies:
      - add-topbar-buttons
      - expand-debug-actions
      - render-perf-telemetry
---

## User Requirements

在打包安卓测试包前，为当前游戏界面补充触摸可用的调试入口，避免依赖键盘快捷键；同时在界面中直接显示不同模拟模块的计算耗时，便于在安卓设备上测试性能与定位卡顿。

## Product Overview

当前主界面已有地图视图、顶部状态栏、暂停与倍速按钮，以及可开合的调试控制台。需要扩展为更适合安卓测试的调试界面：通过按钮完成重新生成、适配视口、打开调试控制台、切换调试开关、执行诊断动作，并在控制台内实时查看模拟耗时。

## Core Features

- 在主界面提供触摸按钮，覆盖常用键盘调试操作：重新生成地图、适配视口、显示/隐藏调试控制台。
- 在调试控制台增加更多诊断按钮，覆盖现有快捷键调试能力，如 DataCore 开关、验证快照、soak dump、性能结论等。
- 在调试控制台 Telemetry 区展示 fast tick 总耗时、SUS/模拟调度耗时、最大耗时模块、各模拟模块最近一次耗时、跳过原因与进度。
- 复用已有暂停、倍速、Overlay、模拟开关、视觉开关，不改变地图主体视觉效果。
- 调试界面应适合安卓触摸操作，按钮尺寸清晰，文本紧凑可滚动，不遮挡主地图核心区域。

## Tech Stack Selection

- 引擎与脚本：Godot 4 + GDScript，沿用现有 `Project/project-keynes` 项目结构。
- UI：Godot `Control` / `PanelContainer` / `ScrollContainer` / `VBoxContainer` / `Button` / `Label`，复用现有动态构建的 `DebugConsole`。
- 性能数据来源：复用 `SlicedUpdateScheduler`、`DCSystemScheduler`、`MapGenerator` 与 `main.gd` 已有耗时统计，不新增重复计时体系。

## Implementation Approach

本方案采用“最小侵入扩展现有调试控制台”的方式：将安卓无键盘场景需要的快捷键能力映射为 UI 按钮，并把已有控制台日志中的模拟耗时报告转换为 1Hz 刷新的可视化文本。核心决策是复用 `debug_console.gd` 动态 UI 与 `main.gd` getter/diagnose 方法，避免在巨大的 `main.gd` 中继续堆叠大量 UI 逻辑。

性能方面，耗时展示只读取上一 tick 缓存报告，主要是小字典复制和少量 Label 更新；刷新频率沿用 DebugConsole 的 1Hz Timer，避免每帧 UI 重排。模拟模块耗时来自已有 `sus_report_last_tick()`、`sus_report_last_tick_summary()`、`sus_*_breakdown()`，不会增加模拟热路径成本。

## Implementation Notes

- `main.gd` 已有键盘入口包括 `R/F/Space/F1/F2/F3/F6-F12`，按钮应调用同一批已存在的方法或提炼出的公共方法，避免复制逻辑。
- `debug_console.gd` 当前通过 `_main.call()` 间接访问状态，新增按钮与耗时展示应继续使用此模式，保持 DebugConsole 不持有 `MapData` 引用。
- 对外新增 getter 应返回 `duplicate(true)`，避免 UI 意外修改调度器内部统计字典。
- TopBar 的 `InfoLabel` 当前显示键盘提示，应改为更适合触摸设备的提示；已有 Pause/x1/x5/x20 保留。
- 日志按钮应避免泄露大量数据到 UI；控制台打印类动作仍用现有 `print`/`push_warning`，UI 只显示摘要。
- 不处理实际 Android export 配置，先完成测试包前所需的界面调试能力。

## Architecture Design

现有结构适合扩展为：

- `main.gd`：主运行状态、调试动作入口、只读性能 getter。
- `debug_console.gd`：触摸调试控制台、按钮分组、Telemetry 展示。
- `main.tscn`：顶部栏补充移动端调试按钮节点。
- `MapGenerator` / Scheduler：继续作为性能数据源，不直接耦合 UI。

数据流：
用户点击按钮 → DebugConsole 或 TopBar 调用 `main.gd` 公共方法 → 复用现有调试/诊断逻辑 → `DebugConsole` 1Hz 读取 `main.gd` getter → 展示 fast tick 与各模拟模块耗时。

## Directory Structure

```
Project/project-keynes/
├── scenes/
│   └── main.tscn
│       # [MODIFY] 顶部栏新增触摸调试按钮，如 Debug、Regenerate、Fit。
│       # 保留现有 Pause/x1/x5/x20，调整 InfoLabel 文案，避免只提示键盘快捷键。
│
└── scripts/
    ├── main.gd
    │   # [MODIFY] 增加按钮绑定与公共调试动作方法。
    │   # 提供只读性能 getter：最近 SUS tick summary、last report、模块 breakdown。
    │   # 将键盘处理与按钮处理复用同一逻辑，减少重复分支。
    │
    └── ui/
        └── debug_console.gd
            # [MODIFY] 扩展动态 UI。
            # 新增移动端调试动作按钮区与模拟耗时 Telemetry 区。
            # 1Hz 刷新展示每个模拟模块 elapsed_ms、stage、substage、path、progress、skipped_reason。
```

## Key Code Structures

无需新增复杂接口；只需在 `main.gd` 暴露少量字典 getter，例如：

- `get_sus_last_tick_report() -> Dictionary`
- `get_sus_last_tick_summary() -> Dictionary`
- `get_sim_breakdowns() -> Dictionary`

## Design Approach

调试 UI 采用“顶部轻量入口 + 左侧滚动控制台”的结构。顶部栏只放高频按钮，保持地图视野；详细调试项集中在 DebugConsole 内，通过 ScrollContainer 支持安卓小屏滚动。

## Page / Screen Planning

仅改造主游戏界面一个屏幕：

1. 顶部状态栏：地图信息、时间、气候、Debug、Regenerate、Fit、Pause、倍速按钮。
2. 调试控制台：Overlay、模拟开关、视觉开关、诊断动作、性能监视分区。
3. 性能监视区：总耗时摘要、最大耗时模块、模块耗时列表、子阶段 breakdown。
4. 诊断动作区：将原键盘快捷调试动作变成触摸按钮。

## Block Design

- 顶部按钮组：使用紧凑横向按钮，文字短，如“Debug”“Regen”“Fit”，保证安卓可点击。
- 控制台标题区：保留关闭按钮，标题明确为“调试控制台”，点击外部不穿透。
- 诊断动作区：按钮按风险分组，普通诊断在前，DataCore/soak 类动作靠后。
- 性能监视区：采用等宽风格短文本，每行一个模块，慢模块可用强调色。
- 滚动体验：控制台高度保持现有 520 左右，内容增多后纵向滚动，不扩大遮挡范围。

## Agent Extensions

### Skill

- **civ-grounded-development**
- Purpose: 按仓库既有 Godot/Civ 模拟架构进行读优先、复用优先的实现。
- Expected outcome: 避免新增重复调试系统，复用现有 DebugConsole、main.gd 与 SUS 性能报告。

### SubAgent

- **code-explorer**
- Purpose: 在实施前继续核对相关快捷键、UI 节点、性能统计 getter 与调用链。
- Expected outcome: 精准定位需要修改的文件与函数，避免误改模拟热路径。