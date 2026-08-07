# Country Scheduling and Joint Save

## PKSV coordinator boundary

`GameSaveCoordinator` freezes new clock advancement and drains an already-open
country/economy continuation once per rendered frame. Capture begins only when
the country report is idle and the economy report is committed. PKSV restore
regenerates/configures the world first, then restores PKCN before PKEC, and PKFG
after both. This is the product-level wrapper around the native joint-save rule;
details and all sections are in
[`game-flow-start-save.md`](./game-flow-start-save.md).

## COUNTRY_GRAPH

`CountryDailySystem` 注册为 `country_daily`，priority `255`，`must_run=false`，
`use_job_should_run=true`，位于 `economy_daily` priority `260` 之前。没有到期命令时
`country_should_run()` 为 false，因此不产生 slice。

原生阶段诊断 ABI：

```text
command_preflight -> command_apply -> aggregate_publish
```

报告包含 cursor、changed cells/countries、generation/hash、阶段 timing、pending latency、
`published_to_slot` 和 `country_day_barrier`。超过 `country_max_commands_per_slice` 的原子批次把
SoA staging、稀疏 cell delta、事件和 cursor 保留在 C++，通过真实帧 continuation 完成全部预检；
中间 slice 不修改 committed state，最终只应用/重建 CSR/发布一次。WorldClock 将
`country_day_barrier` 与经济 deadline barrier 一样视作硬屏障，先续跑 country，再允许经济开启新冻结周期。

大批领土命令应尽量按 cell 升序提交。运行时会识别 cell 唯一且有序的纯
`TRANSFER_TERRITORY` 批次，使用直接稀疏发布快路径；混合命令或重复 cell 仍走通用 staging
delta 的完整预检。纯领土批次不会复制其不可能修改的科技和国库矩阵。

## PKCN v6 / PKEC v31

PKCN v5 adds country-owned research-signal evidence. Permanent discoveries are
stored as a dense `country × signal` bitset; observed `(signal, cell)` pairs and
first/last-day provenance remain sorted sparse vectors. `DISCOVER_COUNTRY_SIGNAL`
is idempotent per country/signal/cell and is committed through the normal country
command barrier. The static signal catalog and its stable IDs participate in the
country catalog hash, so v4 and older PKCN streams are explicitly rejected.

当前 writer 写出 PKCN v6 与 PKEC v31。PKCN v6 在国家研究、研究信号、税务政策和
Country Modifier 状态之外，持久化原生 Country Effect ingress 的 prepared/committed
结果与命令幂等记录；PKEC v31 在既有经济、家族、建筑身份和生产气候状态之外，
持久化原生 Economy Effect ingress 的待处理结果与幂等证据。恢复后以相同 Effect
command idempotency key 重投只会补齐 ACK，不会重复授予。reader 仅接受当前 schema；
旧版本与 catalog mismatch 均明确拒绝。恢复仍必须先 PKCN 后 PKEC。

历史 PKCN v3 增加完整国家研究状态；PKEC v22 在
v21 科技值采购累计基础上增加生产气候冻结与诊断字段。经济旧版本统一返回
`legacy_climate_production_save_unsupported`，不再迁移为空 store。以下旧版段落仅保留历史背景；
当前契约以[科技树、科技值与科研经济运行时](./technology-tree-runtime.md)为准。

PKCN v2 流式保存 catalog identity、国家记录、领土、科技、国库商品、future pending commands、
Country Modifier domain 和 end marker。读取验证 stable catalog、cell/good/technology shape、
水域领土和领土计数；v1 确定性迁移为空 Country Modifier store。

PKEC v20 不保存全局国库与逐地块科技，header 记录对应 PKCN schema、generation 和 state hash；
除既有经济 sections 外，v20 保存 BuildingIdentityStore 与 Economy Modifier domain，v18/v19
确定性迁移为空 store。
恢复顺序必须是 PKCN 后 PKEC；顺序或交叉 hash 不一致返回
`economy_country_restore_order_or_hash_mismatch`。

## PKFG v1（视野）

PKFG 不属于国家权威，但恢复顺序依赖它：视野解算以玩家领土为源，所以 `pkfg` 必须
排在 PKCN 之后。它只存单调的 `cell_explored`，当前可见性与知识度 `fog_k` 在恢复后由
`WorldRuntimeHost.refresh_country_visuals()` 重算。领土变更（`country_committed`）
同样触发这条链路，顺带重建国界 mesh。契约细节见
[视野迷雾与国界线](./vision-fog-and-borders.md)。

联合存档要求国家命令图在当前 committed day idle，且经济位于 committed boundary。PKEC v10
迁移为空贸易状态并在加载后重建拓扑；PKEC v2-v9 不兼容，读取返回
`legacy_countryless_economy_save_unsupported`，不再执行旧科技/国库迁移默认值。国家归属变化
只影响新订单，已发运订单不写回或修改 PKCN schema。

## 验证

最低验证序列：schema/binding 静态检查、debug/release GDExtension、国家 focused test、PKCN+
PKEC round-trip、PKFG `explored` round-trip 与恢复后国界/视野一致性、经济守恒/worker-scalar
hash、30+ tick ACTIVE soak，以及 100k territory update、200k/10M cohort 基准。
