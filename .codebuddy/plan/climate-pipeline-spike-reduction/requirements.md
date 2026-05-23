# 需求文档

## 引言

本功能旨在继续收敛地图生成与气候系统中的主线程尖峰，将当前已经局部优化的海冰、Atlas smooth、generic climate pass、weather fronts 发布链路以及 DOTS 迁移工作推进到更完整、可观测、可中断、可分片的最终形态。

核心目标是把容易在极端 dirty、full sweep 或大地图初始化时集中执行的工作拆分为跨多 tick 的确定性流程，降低单帧耗时峰值，同时保持地形、气候、渲染发布结果的一致性与可回滚性。该规划仅定义需求，不包含具体实现步骤。

## 需求

### 需求 1：Sea ice 多 tick 状态机化

**用户故事：** 作为一名性能优化开发者，我希望将 sea ice 从单次 apply_terrain 尖峰缓解改造成完整多阶段状态机，以便在大规模海冰更新时稳定控制单帧耗时。

#### 验收标准

1. WHEN sea ice 更新被触发 THEN 系统 SHALL 将流程拆分为 `native_compute`、`dense_sync_chunk`、`terrain_flip_chunk`、`commit` 等可观测阶段。
2. WHEN 单个 tick 的 sea ice 工作量达到预算上限 THEN 系统 SHALL 暂停当前阶段并在后续 tick 从游标位置继续执行。
3. IF sea ice 计算结果尚未完成全部阶段 THEN 系统 SHALL 不提交会导致地形状态半成品可见的变更。
4. WHEN sea ice 状态机完成 `commit` 阶段 THEN 系统 SHALL 以一次一致性提交方式发布最终地形与相关派生状态。
5. IF sea ice pass 在执行过程中被新一轮地图生成、气候重算或取消请求打断 THEN 系统 SHALL 能够安全 abort 并清理中间状态。
6. WHEN 启用性能诊断 THEN 系统 SHALL 记录各阶段耗时、处理数量、剩余游标和是否触发预算中断。

### 需求 2：Atlas smooth dirty 膨胀与 prep 分片化

**用户故事：** 作为一名地图渲染与生成维护者，我希望 Atlas smooth 不仅切分 step，还能切分 dirty 膨胀和 prep 阶段，以便避免极端 dirty 或 full sweep 场景下的单帧尖峰。

#### 验收标准

1. WHEN Atlas smooth 收到 dirty 区域 THEN 系统 SHALL 将 dirty 膨胀、prep 和 smooth step 都纳入统一预算控制。
2. WHEN dirty 区域接近 full sweep THEN 系统 SHALL 采用分片或游标推进方式处理，而不是在单 tick 内完成全部预处理。
3. IF dirty 膨胀产生重复或重叠区域 THEN 系统 SHALL 保持去重后的确定性处理顺序。
4. WHEN Atlas smooth 分片执行跨越多个 tick THEN 系统 SHALL 保证最终结果与一次性执行在逻辑上等价。
5. IF 当前地图尺寸、dirty 数量或 full sweep 状态超过安全阈值 THEN 系统 SHALL 启用降峰路径并输出可诊断指标。
6. WHEN Atlas smooth pass 被取消或被新 dirty 请求替代 THEN 系统 SHALL 能够释放临时缓冲并避免提交过期结果。

### 需求 3：Generic climate chunk API 抽象化

**用户故事：** 作为一名气候系统开发者，我希望抽象通用 climate chunk API，以便 ocean water、land、sea ice 及后续气候 pass 共享一致的分片执行、取消和预算机制。

#### 验收标准

1. WHEN 任一 climate pass 需要分片执行 THEN 系统 SHALL 通过 `begin_climate_pass`、`run_climate_pass_slice`、`abort_climate_pass` 或等价抽象管理生命周期。
2. WHEN pass 开始执行 THEN 系统 SHALL 初始化 pass 类型、范围游标、预算参数、临时缓冲和诊断上下文。
3. WHEN pass slice 被调用 THEN 系统 SHALL 在预算范围内推进指定 chunk/range，并返回完成、未完成或失败状态。
4. IF pass 被 abort THEN 系统 SHALL 清理 native 与脚本侧中间资源，并保证不会继续发布该 pass 的过期结果。
5. WHEN ocean water、land、sea ice 使用 climate chunk API THEN 系统 SHALL 保持各自现有输出语义不变。
6. IF 新增 climate pass 需要接入分片执行 THEN 系统 SHALL 能通过通用 API 接入，而不是复制独立 range cursor 编排代码。

### 需求 4：Weather fronts 增量 diff/signature 与发布体系收敛

**用户故事：** 作为一名天气系统与渲染维护者，我希望 weather fronts 的 diff、signature 和 renderer 发布链路进一步增量化，以便减少重复发布、重复渲染刷新和主线程抖动。

#### 验收标准

1. WHEN weather fronts 数据更新 THEN 系统 SHALL 基于 diff/signature 判断哪些 fronts、cells 或渲染片段发生了有效变化。
2. WHEN signature 未变化 THEN 系统 SHALL 跳过不必要的 renderer/fronts 发布与刷新。
3. WHEN 仅局部 weather fronts 变化 THEN 系统 SHALL 只发布受影响的增量范围，而不是全量重建发布。
4. IF 增量 diff 结果与当前 renderer 状态不一致 THEN 系统 SHALL 能够回退到安全的全量同步路径。
5. WHEN weather fronts 增量发布完成 THEN 系统 SHALL 保证渲染可见状态与气候数据源一致。
6. WHEN 启用诊断 THEN 系统 SHALL 记录 diff 命中率、signature 跳过次数、增量发布数量和 fallback 次数。

### 需求 5：DOTS 迁移边界收敛

**用户故事：** 作为一名底层性能优化开发者，我希望继续迁移仍由 GDScript 执行的 ocean begin 打包/初始化循环和 sea ice 提交编排，以便减少脚本层大循环造成的初始化与提交尖峰。

#### 验收标准

1. WHEN ocean begin 初始化执行 THEN 系统 SHALL 将可迁移的打包、初始化和大循环工作从 GDScript 侧下沉到 DOTS/native 路径。
2. WHEN sea ice 提交流程执行 THEN 系统 SHALL 尽量通过 DOTS/native 或统一 chunk API 编排批量提交，减少 GDScript 逐项循环。
3. IF 某段逻辑因依赖 Godot API 无法迁移 THEN 系统 SHALL 保留最小脚本边界，并将重计算或批量数据准备放在 native 侧完成。
4. WHEN DOTS/native 返回结果给 GDScript THEN 系统 SHALL 使用批量结构或压缩结果，避免大规模逐 cell 脚本交互。
5. IF DOTS 迁移路径出现异常 THEN 系统 SHALL 能够 fallback 到现有正确路径或给出明确错误诊断。
6. WHEN 完成迁移后 THEN 系统 SHALL 对比迁移前后的主线程耗时、分配量和结果一致性。

### 需求 6：统一预算、调度与可观测性

**用户故事：** 作为一名负责稳定帧时间的开发者，我希望这些 pass 共享一致的预算、调度和诊断规范，以便定位尖峰来源并控制多系统同时运行时的总成本。

#### 验收标准

1. WHEN 多个 climate/geography/weather pass 同时存在待处理工作 THEN 系统 SHALL 通过统一调度策略限制单 tick 总耗时或总处理量。
2. WHEN 某个 pass 连续多 tick 未完成 THEN 系统 SHALL 暴露剩余进度、当前阶段和预计处理规模。
3. IF 某个 pass 超出单帧预算 THEN 系统 SHALL 记录超预算阶段、输入规模和处理数量。
4. WHEN pass 被取消、重启或替换 THEN 系统 SHALL 保证旧 pass 不会覆盖新 pass 的结果。
5. WHEN 运行极端 dirty/full sweep、大地图或密集 weather fronts 场景 THEN 系统 SHALL 提供可比较的性能指标以验证尖峰收敛效果。
6. IF 诊断开关关闭 THEN 系统 SHALL 避免引入显著额外开销。

### 需求 7：正确性、回归与成功标准

**用户故事：** 作为一名项目维护者，我希望性能改造不改变地图和气候的最终语义，以便在降低尖峰的同时保持现有玩法与视觉表现稳定。

#### 验收标准

1. WHEN 使用相同 seed、地图参数和气候输入运行生成流程 THEN 系统 SHALL 在允许的浮点误差范围内产生与既有逻辑一致的最终结果。
2. WHEN pass 被拆成多 tick 执行 THEN 系统 SHALL 保持确定性，不因帧率或 tick 切片大小不同而产生不同最终状态。
3. IF 出现取消、重启、full sweep 或 dirty 爆发 THEN 系统 SHALL 保持数据结构一致且不会遗留过期中间状态。
4. WHEN 性能改造完成 THEN 系统 SHALL 覆盖典型场景、极端 dirty、full sweep、大地图、密集 weather fronts 和中途 abort 场景的验证。
5. WHEN 对比改造前后性能 THEN 系统 SHALL 证明主要尖峰阶段的单 tick 耗时下降，且总耗时没有出现不可接受的退化。
6. IF 无法满足某个性能目标 THEN 系统 SHALL 通过诊断数据明确剩余瓶颈位置。
