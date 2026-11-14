# 目标架构

本页写迁移方向。每节标出**已落地**的部分，其余都是**目标，尚未实现**。今天的行为读 [current-state.md](current-state.md)，不能按本页假定已有接口。

## 为什么这样设计

目标是让改一个模块的人（或 AI）只需读这个模块和它依赖的接口头：契约稳定、边界由护栏机检，多个模块能并行修改而不互相踩。所以每条规则都要能被检查脚本判定，而不是靠约定。

## 确定性推进

一次 tick 是一个模拟日，有明确的输入与提交结果。种子、初始内容版本和有序命令日志决定结果；帧率、后台线程唤醒、分片预算只决定什么时候完成，不能决定业务结果。同一天重试必须沿用冻结输入和请求身份。

顺序为：冻结输入（Freeze）→ 按模块依赖计算（Plan）→ 完成跨域请求（Resolve）→ 所有者提交（Apply）→ 发布已提交视图（Publish）。

**已落地**：十二域固定顺序表与 `static_assert`；`RuntimeFrozenInputVersion` 在 Climate、Country、Economy 登记；描述符 reads 推导的顺序检查（只报错，不重排）；四个请求队列共享入队与顺序键；三个 Apply 入口的写集合检查。

**目标，尚未实现**：Climate 并入表内 Freeze（今天在表前提交）；通用纯 Plan；全域统一去重；全域原子提交与失败回滚；消除剩余软完成。

## 模块与接口

每个模块只经两扇门与外界交互：

- `<module>_api.h`：别的模块调用它。只放 POD、枚举、常量、前向声明和一行转发函数，不暴露运行时布局。
- `<module>_host_port.h`：它调用宿主。纯虚接口，签名与宿主方法一致。

运行时由组合根（宿主 `native_simulation_*`、绑定层 `world_ext*`）构造和拥有。

**已落地**：Economy、Country、Modifier、Military 的接口契约；Economy、Country 的宿主端口；军事核心只依赖 `military_bridge.h`。见 [module-boundaries.md](module-boundaries.md#模块公开接口)。

Country 的国家级政治体制沿用上述接口：体制 stable id 与 capability bit 由 Country
拥有，Economy 只读取已提交并冻结的 `CountryReadView`。政治 UI 是 Country 体制快照与
Ideology 快照的组合视图，不形成新的每日调度域。

**目标，尚未实现**：Effect、Trigger、Ideology、Climate 的接口头；其余模块的宿主端口；组合根数量继续收缩。

## 跨模块规则

只允许两种交接：读取所有者发布的不可变视图；向所有者提交有明确结果的业务请求（intent）。请求包含稳定身份、目标、日期和去重信息，所有者决定接受、等待或拒绝。消费者不能持有另一模块的可写容器，不能绕过所有者补钱、改人口或发布伪成功。

**已落地**：9 条已提交视图；Economy→Country 全部写入走所有者端口（直接写为 0）；30 个域对逐项登记。

**已落地**：Military 的玩家自动探路任务留在 `MilitaryCore`，只接收 Host 冻结的玩家 explored
副本并返回实际进入格的 trail；Host 合并 `MapData.explored_arr`，`VisionSolver` 仍是
`visible/fog` 的唯一生成者。探路不宣战、不占领、不改变控制权，也不建立第二套视野算法。

**目标，尚未实现**：剩余读边（见 current-state）改为已提交视图；25 个待核查域对的逐函数语义审查。依赖棘轮冻结的现有债务不是永久许可。

## 模块描述符

**已落地**：`runtime_module_descriptor.h` 定义 id、域、阶段成员函数、reads/writes、是否限主线程；cadence、视图版本、intent 类型、store、存档段登记在 `runtime_module_contracts.json`，由 `check_module_contracts.py` 核对。

**目标，尚未实现**：由内核检查依赖与所有权、自动排序、禁止绕行。当前声明不等于访问隔离。

## 黄金回放

目标记录每拍每域的规范化状态摘要，链接前一天摘要、输入与命令身份；排除计时、地址和诊断次数；用重复运行、不同分片、保存恢复和不同线程方式验证同一条链。

**已落地**：五条固定链（开局账目、整体经济、七域投影、Country、表外推进者）；四条轨迹的保存续跑矩阵，包括 365 日与非零军队。

**目标，尚未实现**：完整十二域状态哈希；多种子、跨平台、实际战斗占领。运行时 SHADOW/parity 在覆盖充分前保留。

## 存档与显示

每个模块拥有版本化的保存段；恢复先检查完整性、内容身份和依赖，再安装状态。保存的必须是真实继续所需的数据，不能只存游标。

**已落地**：12 个 C++ 域的段契约（版本、恢复依赖、旧版拒绝）；Country、Economy 的脚本 provider 契约；开发期旧版明确拒绝。

**目标，尚未实现**：所有 provider 统一注册；统一的候选安装与世界级回滚。

Godot 对象、图像和 GPU 上传由主线程负责；VISUAL 域只产生刷新意图。
