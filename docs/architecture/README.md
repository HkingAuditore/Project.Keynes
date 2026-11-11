# 模拟内核架构

本目录是运行架构的入口，按主题组织：

1. [module-map.md](module-map.md)：从这里开始。按任务找入口；每个模块的所有者文件、接口头、存档段、测试和 skill。
2. [design.md](design.md)：目标架构，标明哪些已落地。
3. [current-state.md](current-state.md)：今天源码里的十二域、表外推进者、跨模块交接、存档段、哈希与验证范围。
4. [module-boundaries.md](module-boundaries.md)：数据归属、模块公开接口与宿主端口、依赖棘轮、已提交视图、请求与提交、行数棘轮。
5. [development-guide.md](development-guide.md)：怎样改模块、加接口/端口/读边/请求/存档字段、搬迁文件、跑检查、维护黄金基线、做性能验证。
6. [migration.md](migration.md)：迁移目标各项的状态、推迟项和最近一次验证。
7. [source-module-splits.md](source-module-splits.md)：19 处增长超限的职责拆分、当前实现位置与输入边界。
8. [feature-guides.md](feature-guides.md)：单个功能的专项约束与验证入口，改到该功能时才读。
9. [feature-status.md](feature-status.md)：单个功能的现状与带日期的验证记录。

规则：

- 代码与文档不符时，以代码和可复现的运行结果为准。
- 目标设计、代码接入、实跑验证是三种不同结论；拆文件不等于所有权迁移完成。
- 改了架构就同步改对应页面，只写现状，不按阶段追加日志。过程记录留在提交信息和 git 历史里。
- design、current-state、module-boundaries、development-guide 只放对所有模块成立的内容。单个功能的约束写进 feature-guides，带日期的现状与验证记录写进 feature-status 或 migration 的验证记录。

构建和平台说明见 [从源码构建](../build-from-source.md)。实测平台为 macOS arm64、Godot 4.6.3，只做过无界面验证。

## 业务规格文档

`docs/cpp-dots-runtime/` 和 `docs/plans/` 保存业务规则和玩法设计，不是架构状态入口。引用前核对其中的版本号和接口是否仍与代码一致。

| 级别 | 含义 | 文件 |
|---|---|---|
| 参考 | 业务规格；核对所列版本和实现后可用 | `cpp-dots-runtime/` 下的 annual-development-report、canal-runtime、country-ai-runtime、domestic-trade-runtime、family-colonization-runtime、player-controller-runtime |
| 参考／玩法依据 | 业务规格，其中的玩法取舍改动前要问用户 | `cpp-dots-runtime/` 下的 economy-fixed-point-ledger-formulas、era-advancement-runtime、era-reward-runtime、family-demography-ledger-design、military-recruitment-pipeline、military-runtime、notable-family-runtime、notable-person-runtime、price-v6-validation、satisfaction-runtime、tax-fiscal-runtime |
| 历史／玩法依据 | 决策来源；不能当完成状态的证明，原始意图保留 | `plans/` 下的 army-pay-contract、army-personnel-contract-2、army-personnel-implementation-contract、military-implementation-contract，以及 `plans/ideology-review/` 的 01、02、03、05、09、22 两份 |
| 玩法设计 | 原文保留，由用户决定 | `plans/military-system-design.md` |

其他文件未分级，使用前先核对代码。

已知过时：`plans/army-pay-contract.md` 里的军饷经 `military_collect_cash` 已改为所有者端口，但“国库减多少、lane 加多少”的守恒意图仍有效；`plans/military-implementation-contract.md` 的“无需新经济 opcode”已过时。
