# M5-21 skill 同步（§16.5）

| 项目 | 内容 |
|---|---|
| 里程碑 | [§16.5](22-cell-program-cap-removal-plan-v3.md) 文档与 skill 同步 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **派生层章节已补进 2 个 skill × 2 个镜像**；发现 4 处既有镜像分歧，修了 2 处、拒绝 2 处 |

## 1. 补了什么

### 1.1 `project-keynes-ideology-runtime` → `references/runtime-contract.md`

新增 §7「Derived cell layer (permanent cell cards)」，并更新目录：

| 小节 | 内容 |
|---|---|
| Backend decision (I01) | `cell_program_eligibility.h` 是唯一判定处；覆盖率 265/265；23 个有理由留在实例路径；**没有 rollout 开关** |
| Rebuild is resumable | `step_derived_rebuild` / `derived_rebuild_pending` / `drain_derived_cell_layer`；工作单元是 contribution；`done()` 的 `_started` 细节；采集与折叠必须分两步的实测原因 |
| **Ownership scope** | bit 12..13 的 OWN/FOREIGN/ANY；**未知值回退 ANY 而非 OWN** 的理由；**74 张卡受影响**；边境 R2 环 **51.7%** 落外国 |
| Where the value comes from | §5.1 单次 clamp 的合并式；**`group_handle` 就是 cell，不要加 `!= 0` 守卫**（cell 0 缺陷）；ramp 幅度必须来自指令流 |
| Observability | 4 个桥的字段表；`get_effective_stat_value` 走生产同一调用 |
| Idle must not look like work | I13；B5 夹具；**`cell_layer_rebuild_steps` 不是累积计数** |
| Known gap | **没有 >32 格的生产样例**（真实世界 `widest=1`）|

### 1.2 `project-keynes-modifier-runtime` → `references/architecture-and-data.md`

新增「Derived Cell Layer」章节：`DerivedCellFront` / `DerivedCellContribution` 结构、
二分查询的理由、§5.1 合并规则与「为什么不能先 clamp 再合并」、零因子必须归零整个 product、
**哪个 handle 是 cell**（含 cell 0 缺陷的完整记录与移除安全论证）、
安装的原子性与 I13、可续跑物化器。

## 2. 顺带发现的镜像分歧（§16.5 要求镜像一致）

工具化比对两棵树后，modifier skill 有 **4 个文件不一致**：

| 文件 | claude 行 | agents 行 | 处理 |
|---|---:|---:|---|
| `SKILL.md` | 99 | 113 | **已同步** `.agents → .claude` |
| `references/domain-integration.md` | 40 | 47 | **已同步** `.agents → .claude` |
| `references/scheduling-save-and-verification.md` | 49 | 52 | **拒绝** |
| `scripts/verify_modifier_runtime.ps1` | 107 | 115 | **拒绝** |

### 为什么拒绝后两个

同步脚本只做「严格超集」方向。这两个文件 `.claude` 有**独有行**，例如：

- `PKEC v33: Economy state, family-cell effects, BuildingIdentityStore, Economy store.`
- `'"pkcm"', '"pkgp"', '&"pkcn", 10', '&"pkec", 33'`

而 `.agents` 写的是 **PKEC v41**。

**看起来 `.claude` 是旧版本**，但我**不能确认**：
代码里各 runtime 的 schema 是分开的（effect=14、ideology=10、modifier=3、trigger=6），
**PKEC 容器版本号无法从这里判定**。

**强行覆盖可能销毁某一侧的知识。这类超出本目标范围的分歧，我记录而不猜。**

## 3. 现在的镜像状态

```
same=11  differ=2  claude_only=0  agents_only=0
```

11 个文件一致（含我改的 2 个），2 个已知分歧（上表后两行），没有孤儿文件。

## 4. 局限

- 只处理了 ideology 与 modifier 两个 skill；§16.5 还列了 economy、runtime-architecture 等。
- 未补「归属筛选」到 economy skill（它也会看到 `cell_country_slot` 的调用）。
- 2 个分歧文件留给 owner 判定。

## 5. 交付物

| 文件 | 说明 |
|---|---|
| `.claude`/`.agents` × `ideology-runtime/references/runtime-contract.md` | +§7，镜像一致 |
| `.claude`/`.agents` × `modifier-runtime/references/architecture-and-data.md` | +Derived Cell Layer，镜像一致 |
| `.claude` × `modifier-runtime/SKILL.md`、`references/domain-integration.md` | 从 `.agents` 同步 |
