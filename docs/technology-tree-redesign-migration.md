# 科技树重构迁移边界

这轮产物是设计与审计基线，不会自动替换生产科技网络。

## 稳定 ID

- 默认保留 `tech.*` stable ID。
- 节点重命名、重挂硬前置、补充 reveal/research route 或重新绑定内容时，沿用原 ID。
- 只有语义完全合并且无法保留原含义时才允许改 ID；改 ID 必须在迁移矩阵中同时记录旧 ID、新 ID、替代节点和存档影响。
- 任意生产数据变更都会改变 catalog identity；旧 PKCN/PKEF/PKTR/PKEC 按现有 `catalog_hash_mismatch` 策略处理，不静默映射。

## 实施顺序

1. 主干和时代里程碑：先稳定研究入口、时代门槛和前置闭包。
2. 核心产业支线：农业、畜牧、材料、水利、贸易、测量和公共卫生。
3. 现代能力支线：能源、控制、信息、生物和智能时代。
4. 长尾与展示：合并重复节点、补充中文名称/效果摘要、完善来源追溯。

每一波都必须先通过设计审计和内容闭包，再进入 runtime、Effect、Modifier、Economy、存档和 UI 回归。

## 不在本轮迁移中的内容

- 不新增独立 `TechnologyRuntime`。
- 不扩展研究条件谓词。
- 不改变 Country、Economy、Effect、Modifier 的 authority 边界。
- 不自动修改生产 `Project/project-keynes/data/technology/technology_network.json`。
