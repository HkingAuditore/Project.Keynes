# 2026-09-19：迁移设计与实际生产路径对照

> 后续修复更新：以下表格保留首次审计时点。现已实现 worker 日边界自动切换、
> immutable Economy 输入包，且 player_game 默认开启自动 POD_ACTIVE。
> 最新默认入口 90 秒 soak 验证 owned_state、切换 1 次、worker faults=0；
> 吞吐 36.253 日/秒、最大提交间隔 1073.629ms，严格门槛仍失败。
> 同代码显式开启的一轮为 44.977 日/秒（4048 日/90 秒），不能用最佳样本宣称稳定达标。

本次核对依据 `authority-migration.md` 的 1.2、2.3、2.8，以及
`economy-ledger-migration-status.md` 的 A+Y / N10。历史“已完成”文字不是验收证据。

## 结论

当前是 **worker 执行 StageOps + NER 本地可变数据 + 每日 POD 提交镜像**。
尚未达到专项设计的默认 OwnedState 绑定，也未达到 50 权威模拟日/秒。
`0xFFF`、`economy_pod_active_ready` 和零 worker fault 不能代替这两项验收。
复用 NativeEconomyRuntime 的同源公式符合设计；问题在实际数据归属、边界接线与验收缺口，
不能简单归因为“还调用旧类”。

## 逐项对照

| 原设计 / 声明 | 当前证据 | 判断 |
| --- | --- | --- |
| 主线程捕获 → immutable input → worker POD → committed snapshot | `capture_input_manifest` 封装环境 manifest；Economy 仍在 Prelude 请求同日输入，由主线程 `capture_economy_day_inputs(-1)` 在 try-lock 下写入 NER 的冻结数组 | 部分实现；manifest 不等于完整 Economy 输入包已就绪。主线程捕获本身是允许边界，日内等待成本和取样语义仍需核对 |
| StageOps 为生产 writer | `WorldRuntimeHost` 配置 `stage_ops_mutate=true` / `stage_ops`；实测 requested/effective 均为 stage_ops | 已对齐；总纲仍写 compact-slice 的段落过时 |
| A+Y 默认自动 POD_ACTIVE，公式直接写 OwnedState | `world_runtime_host.gd` 默认 `runtime_economy_auto_pod_active=false`；实测 `formula_backing=ner_local`、ready=true、switch_count=0 | 未对齐；代码注释记录关闭原因是 Effect ACK / Country–Economy day barrier |
| N10 绑定后不替换活跃 OwnedState | Host bound 分支 flush + publish，unbound 分支 capture + import | 分支机制存在且保留，但本次玩家会话走 unbound，所以每天仍重建独立镜像 |
| immutable committed snapshot 为发布边界 | bound StageOps 在 trade settle、trade dispatch、family commit、person commit 后都调用全域 `flush_formula_owned_domain_mirrors`，Host 日末再 flush/export | 不可假设绑定立即消除复制；需审查各阶段消费者，收拢或按脏域更新，禁止盲删必要快照 |
| 跨域 typed intent / ACK，唯一写者 | D7 已有队列、journal、CountryCore prepare/commit；本轮修复遗产现金转移的同步调用收到 pending 后 fatal | 协议已有，操作覆盖仍不完整；尚不能宣称 research/treasury 等全部 continuation 已验收 |
| ECP2 存档切换 | `game_save_coordinator.gd::_write_economy_provider` 实际调用 `facade.capture_ecp2(0)`，restore 使用 ECP2；总纲还列公开 coordinator 切换待做 | 文档落后于实现；本轮未完成 save→reload→继续长跑，因此不把入口落地当恢复验收 |
| 50 权威模拟日/秒 | 最新 60 秒严格 soak：1973 日、32.882 日/秒、最大观测提交间隔 812.573 ms、worker faults=0 | 未通过吞吐门槛 |
| 主线程不等待、worker 无 Godot API、真实客户端不卡顿 | report `main_wait_on_sim_us=0`；输入/切换使用 try-lock；本轮只有 headless 玩家场景路径 | 局部证据；尚无完整 source scan / 全入口竞态审计 / 图形客户端帧验收，不能整体打勾 |

## 性能证据和边界

- `tmp/soak_50x_combinedmirror/session.json`：上一轮约 18.4 日/秒。
- `tmp/soak_50x_demandreuse/session.json`：22.33 日/秒；去掉派生商业需求按商品重复计算完整家庭需求向量。
- `tmp/soak_50x_exacthash/session.json`：90 秒推进 2900 日，32.22 日/秒，faults=0。
- `tmp/soak_50x_strictfinal/session.json`：31.775 日/秒，最大观测提交间隔 826.068 ms，严格验收失败。
- `tmp/soak_50x_resourcehash/session.json`：32.882 日/秒，严格验收失败；与上一轮差别在噪声范围内。

均为 Debug、headless 正式 player 路径，60×40、seed 1735228708、6 国、speed=50，
保留年度自动保存。不是图形 FPS，也不是完整经济行为对拍。
新 runner 可用 `min_native_days_per_second=49 max_commit_gap_ms=1000` 作明确的诊断门槛；
该容差配置不改变文档的 50 日/秒目标。

已验证的局部改动：30 天修改前后逐日完整经济哈希一致；compact/StageOps 190 项通过；
阶段顺序 18 项、POD 8 项通过。字节 FNV 优化保留原哈希 ABI和全量校验。
这些小 fixture 不能证明所有家庭就业行为已经恢复，也不能替代 M0 全回归。

## 后续修复顺序

1. 为 OwnedState 绑定建立正式玩家路径的显式验收，诊断并修复关闭自动切换的 Effect/D7 ACK 原因；不绕过 readiness、in-flight、save 或 fault gate。
2. 绑定验收成功后实测 N10 路径；梳理阶段内全域镜像刷新消费者，将兼容投影的生成收敛到必要边界。
3. 明确 Economy 每个输入字段的来源与日期；让完整输入就绪成为可观测条件，减少逐日主线程往返，但不让 worker 读 Godot/MapData。
4. 补齐操作级 D7 continuation、save/reload 后继续运行、M0 回归及图形客户端帧录制，再验收 50 倍速。按实际数据归属和性能证据更新迁移状态，不能只看 mask。
