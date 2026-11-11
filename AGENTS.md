## Harness

- 找模块的文件、接口、存档段、测试和 skill，先查 `docs/architecture/module-map.md`；功能专项约束写入 `docs/architecture/feature-guides.md`，带日期的现状与验证记录写入 `docs/architecture/feature-status.md`，不写进通用开发指南。
- 新增系统或功能前，阅读 `docs/architecture/design.md` 和 `docs/architecture/development-guide.md`，确定数据归属、模块依赖及接入位置。为后续扩展保留明确接口，并同步维护开发指南和实际迁移状态。
- 架构迁移应先明确目标与模块契约，再接入既有功能并验证；区分目标设计、已实现部分与验证证据，不以拆文件或文档完成代替功能迁移完成。
- 开始修改及推送 PR 前，先拉取上游并核对分支差异；有新改动时先同步，再完成本地验证。
- 推送或更新 PR 前，本地修复审查和测试中已发现的问题并完成回归，不能仅因属于既有失败就留待提交后处理。
