---
name: project-keynes-ui-development
description: Project.Keynes 玩家界面的开发规范与验收标准，涵盖剪纸撕纸手绘风格、布局、动效、文案与内容、图形化、数据展现、易用性、开发流程与事后检查。This skill should be used when designing, implementing, reviewing, refactoring, or auditing any player-facing UI in Project.Keynes (scenes/ui/**, scripts/ui/**, .tscn/.gd, Theme/tres, view models, HUD, panels, tooltips, charts), when fixing UI copy or units, when adding motion, or when running a UI review/checklist. Also use it to resolve conflicts with the older project-keynes-ui-art-direction skill.
agent_created: true
---

# Project.Keynes UI 开发规范

## 用途与优先级

把 Project.Keynes 的玩家界面做成**剪纸 / 撕纸 / 手绘**的科学文明模拟仪表，并且不把实现细节、内部量纲、冗余说明留给玩家。

**冲突裁决（必读）**：仓库内 `.{agents,claude,codebuddy,codex,cursor,dsh}/skills/project-keynes-ui-art-direction/` 把方向定义为「深墨 / 胡桃木 / 羊皮纸 / 黄铜的历史大战略 atlas，参考文明7 / EU5 / V3 / CK3」。**该方向与本项目实际资产和玩家认定不符，以本 skill 为准**。旧文档中仍有效的部分（组件语法、数据获取链、性能约束、中文数字格式）可以沿用；其美术方向章节视为废弃。不得再按 atlas / 霓虹 / 通用 SaaS 风格新增界面。

适用：新增或改动 `scenes/ui/**`、`scripts/ui/**`、Theme/StyleBox、view model、HUD、tooltip、图表；UI 文案与单位修改；动效；UI 审查与验收；多 agent 批量修复。

## 十条铁律

1. **审美**：只用主题里的 `PK*` 纸片样式与剪纸资产。设了 `theme_type_variation = &"PKPaperPopup"` 之后**禁止**再 `add_theme_stylebox_override("panel", ...)` —— 这会把撕纸边顶成圆角纯色板。验证资产引用率，注册不等于上屏。详见 `references/visual-language.md`。
2. **布局**：断点 token 必须接线；按玩家决策 / 因果 / 时间 / 量级排字段，不按原生枚举或代码模块。空态整节不渲染，不保留固定高度容器。1280×720、21:9、移动档必检。详见 `references/content-and-data.md`。
3. **动效**：统一走 `UIAnimation`（Fast 0.10–0.14s / Medium 0.16–0.22s / Slow 0.24–0.32s）；面板开 160–220ms 滑入淡入 ease-out、关 120–160ms ease-in。每个 API 必须查 `reduced_motion()`。禁止散落 `create_tween`、无限循环、与暂停/快进冲突的动画、每 tick 全量重建节点树。详见 `references/interaction-motion.md`。
4. **文案**：玩家文案是 cabinet brief，回答「是什么 / 现在怎样 / 有何风险 / 能做什么」。禁止实现术语（`原生` `runtime` `Q16` `定点` `worker` `POD` `tick` `p95` `SUS` `探针` `冻结` `中性环境` `修订` `1/10000`）、测试/占位字样、内部标识前缀。短标签与数值显式 `AUTOWRAP_OFF`。删文案时连同空容器 / section title / 固定最小高度一起删。
5. **内容**：**禁止无用信息**。两类最容易复发：① 自证性脚注（「条长按当前兵种集归一」「按…归一」「口径」「注：」）——用设计让图形自解释，不写分母；② 空态套话（`无需…` `暂无…` `不计` `—` `读取中…` `暂不可用`）——空即不渲染，不压成一行灰字。**必要信息必须保留**：单位标注、禁用原因、后果提示、量程端点。
6. **图形化**：图标走 `IconCatalog` / `IconBadge` 语义键；禁止 Unicode / emoji 占位（含 `▶ › ▼ — ·`，纯符号行最易漏扫）。状态与枚举用 badge / 色条 / 示意图表达，不只用文字。造好的组件必须接线，避免「36 个组件 29 个只服务 0~1 面板」。
7. **数据展现**：禁止裸数字——每个数值至少带单位 / 基线 / 量程 / 对比 / 趋势之一。图表必须有轴、刻度、单位、图例、零点基准、量程标注；禁止按 `peak/max/hi` 自适应量程却不标上限；同屏共享量程。同一数值同屏只出现一次。写死数量词 / 槽位数必须与实际数组长度一致。禁止无数据时伪造读数。内部缩放因子（`100`、`Q16=65536`、`GOODS_SCALE=1000`、`MONEY_SCALE`）**只在展示层换算**，不改 VM 字段名与原生契约。
8. **易用性**：`FOCUS_NONE` 只在**地图覆盖层模式按钮**合法（测试锁定，防聚焦控件吞掉滚轮/拖拽），其它界面必须有初始 `grab_focus()` 与 `focus_neighbor`。用 push/pop 屏幕栈，不用布尔 `visible` 标志加硬编码关闭链。ESC / 返回语义全局一致。事件驱动，不 `_process` 轮询。每日 tick 只更新缓存、不重建节点树。点击热区 ≥44dp。关键信息不得只在 hover tooltip。有后果的操作要确认 / 撤销 / 禁用原因。
9. **流程**：开发前先读当前实现、确认风格基准、写出玩家要回答的决策问题；数据流固定为 模拟数据 → view model → UI 组件，UI 只读不写模拟。多 agent 并行改同一仓库时，**按文件所有权用 union-find 分区**（共享文件的条目必须同组），工单给独占文件清单并验算交集为空；改前备份；并行期间禁止各 agent 运行 Godot（会抢 `.godot`），统一由主会话验证。按覆盖率收敛判停，不按墙钟时间。
10. **事后检查**：必须跑全项目脚本编译、关键测试、带渲染的截图探针；必须 `git diff -U0` 扫新增行里的套话 / 占位 / 假读数；机械扫描命中**不等于**问题数，须人工复核（本项目实测误报率 61.2%）；不同口径的数字不可直接比较。详见 `references/workflow-and-review.md`。

## 工作流

### 开发前
- 读 `references/antipatterns.md` 的对应类别，确认这次改动不要复发的反例。
- 读当前要改的文件与它的 VM/主题来源；不要凭文件名臆测。
- 写出玩家打开这个界面要回答的 2–3 个决策问题，据此决定字段顺序与哪些数据该进首屏。
- 确认内部量纲的换算点只在展示层。

### 开发中
- 先接既有资产与组件，再考虑新造；先删无用信息，再考虑补充。
- 每个数值标注参照；每个图形自带量程；空态不渲染；短标签关 autowrap。
- 状态色 / 状态 key 写在循环里时用循环变量，不要硬编码单个 key。
- 只改本次范围内的文件，不动数据结构、字段名、信号、存档格式、C++、tests 断言。

### 开发后
按 `references/workflow-and-review.md` 的「验收清单」逐项执行，至少包含：
1. `godot --headless --path <root> --editor --quit` → 0 个 `Parse Error` / `Failed to load script` / `SCRIPT ERROR`。
2. 相关领域测试（例如 `tests/military/military_roster_gate_test.gd`）。
3. 带渲染的截图探针（**不能加 `--headless`**），检查多分辨率与快进状态。
4. `git diff -U0` 逐行看新增文案，确认没有用新套话替换旧假数据。
5. 跑 `scripts/audit_ui.py` 做反模式扫描，人工复核命中后再下结论。

## 资源索引

- `references/visual-language.md` — 剪纸风格基准、资产清单、样式接线、字体、图标、颜色、引用率核查。
- `references/content-and-data.md` — 文案、内容取舍、图形化、数据展现、单位与量纲、量化评估口径。
- `references/interaction-motion.md` — 易用性、焦点、屏幕栈、状态完备、动效参数与实现约束。
- `references/workflow-and-review.md` — 开发流程、并行分区方法、事后检查与验收清单、验证命令。
- `references/antipatterns.md` — 22 类可扫描反模式与本项目真实反例（含文件:行号）、三次误判教训。
- `scripts/audit_ui.py` — 参数化的全库反模式扫描（输出 CSV + 统计 Markdown）。
- `scripts/build_workorders.py` — 多 agent 并行修复的无冲突工单生成器（union-find 分区 + 备份）。

大型任务先读 `references/workflow-and-review.md`；写文案前先读 `references/content-and-data.md`；改样式前先读 `references/visual-language.md`。
