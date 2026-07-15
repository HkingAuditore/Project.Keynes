# Country Scheduling and Joint Save

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

## PKCN v1 / PKEC v12

PKCN v1 流式保存 catalog identity、国家记录、领土、科技、国库商品、future pending commands
和 end marker。读取验证 stable catalog、cell/good/technology shape、水域领土和领土计数。

PKEC v12 不保存全局国库与逐地块科技，header 记录对应 PKCN schema、generation 和 state hash；
相对 v10 新增国内贸易订单、物资行/卖方快照 CSR、货物/现金托管和贸易 EMA。
恢复顺序必须是 PKCN 后 PKEC；顺序或交叉 hash 不一致返回
`economy_country_restore_order_or_hash_mismatch`。

联合存档要求国家命令图在当前 committed day idle，且经济位于 committed boundary。PKEC v10
迁移为空贸易状态并在加载后重建拓扑；PKEC v2-v9 不兼容，读取返回
`legacy_countryless_economy_save_unsupported`，不再执行旧科技/国库迁移默认值。国家归属变化
只影响新订单，已发运订单不写回或修改 PKCN schema。

## 验证

最低验证序列：schema/binding 静态检查、debug/release GDExtension、国家 focused test、PKCN+
PKEC round-trip、经济守恒/worker-scalar hash、30+ tick ACTIVE soak，以及 100k territory
update、200k/10M cohort 基准。
