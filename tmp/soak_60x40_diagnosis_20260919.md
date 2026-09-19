# 60×40 当前迁移后性能诊断（2026-09-19）

## 配置与结论

正式 GameFlow → PlayerGame → WorldRuntimeHost，Stage C client runner；Godot 4.6.2 headless，Debug DLL，seed=1735228708，双大陆，玩家+5外国，speed=50，预热5秒。没有修改生产代码或关闭校验。首次显式 auto_pod_active=true，第二次使用玩家默认自动切换。

| 录制 | 权威提交日 | 权威日/秒 | 最大观察提交间隔 | perf行数 | 帧样本 |
|---|---:|---:|---:|---:|---:|
| 60秒 | 2695 | 44.912 | 732.720 ms | 2662 | 7891 |
| 120秒 | 5250 | 43.660 | 769.797 ms | 5195 | 16015 |

两次均确认 0xFFF authority、owned_state、stage_ops、一次 authority switch，worker fault=0、domain stage fallback=0。第二次退出码3，唯一 health error 是43.660<49日/秒，1000ms提交间隔门槛通过。第一次未设最低吞吐门槛，complete只代表其健康检查通过。不能据此宣布稳定50倍速或全部迁移验收通过。

## 按优先级排列的卡点

1. **年度存档边界的主线程长停顿。** 首轮8个、第二轮15个超过100ms的帧全部位于365的整数倍日；分别516–537ms、533–588ms。第二轮常态帧墙钟median/p95/p99/max=6.899/7.668/10.809/588.017ms，因此只看p99会漏掉这类低频卡顿。game_save_coordinator.gd:211暂停时钟后捕获、收集sections并同步调用write_slot；save_repository.gd:55同步压缩、SHA256及写盘。年度边界与存档路径高度吻合，但尚未对捕获/压缩/哈希/IO单独计时，不应把全部时间归咎于磁盘。优先给这些步骤加独立计时，再评估不可变快照后的后台编码/写盘。

2. **Economy提交镜像及完整账本校验/哈希，是稳态主要成本之一。** 第二轮每100日探针的镜像平均4.234ms、p95=4.955ms、max=5.092ms；约占同批worker日执行平均15.419ms的27%。native_simulation_host.cpp:9119附近会flush domain mirrors并publish_owned_committed_mirror；runtime_economy_pod.cpp:460的export_committed_ledger复制population/market/domain数据，执行valid和recompute_hash。OwnedState消除了权威所有权歧义，但并未消除全部导出复制。economy_graph_stage_dispatch.cpp:258与host提交路径各有一次mirror刷新，是应验证的重复工作候选；两者之间可能存在commit命令修改，不能直接删。

3. **Economy公式执行及最终aggregate发布。** 第二轮formula包围计时平均7.303ms、p95=8.828ms、max=10.068ms；其中13个stage合计平均5.688ms。结束时单次stage快照：AGGREGATE_PUBLISH=2.182ms、PERSON_COMMIT=1.269ms、HOUSEHOLD_MARKET=0.861ms。aggregate的finish_ok还计算完整NativeEconomyRuntime state_hash，不能把阶段标签全解释成纯聚合。stage快照不是全程分布；需要逐阶段稳定采样再细排。prelude平均1.361ms已包含在formula包围计时内，不可重复相加。

4. **Climate与主线程输入处理是次级成本。** 第二轮climate_pod_plan帧观测平均2.146ms、p95=3.173ms、max=4.632ms；fast_ms平均1.535ms、p95=1.852ms、max=6.636ms。visual_apply平均约0.030ms。主线程显式wait_on_sim=0不代表无存档阻塞，也不代表worker没有输入等待。不要用fast_ms或旧SUS窗口推断整图日吞吐。

## 稀疏worker探针统计（120秒，52个每100日样本，单位ms）

| 项目 | avg | median | p95 | p99/max |
|---|---:|---:|---:|---:|
| 整个worker日execute_day_plan | 15.419 | 15.073 | 17.715 | 20.479 |
| Economy formula包围计时 | 7.303 | 7.147 | 8.828 | 10.068 |
| 内含stage合计 | 5.688 | 5.663 | 7.227 | 8.119 |
| 后续mirror包围计时 | 4.234 | 4.144 | 4.955 | 5.092 |
| 内含prelude | 1.361 | 1.297 | 1.723 | 1.919 |

每100日采样会偏向周期性工作，不等于所有日的分布；frame CSV中的last_*为重复观察值，不是独立执行样本。未运行5次匹配重复或A/B，不宣称两个录制之间的差异是性能回归。没有GPU/FPS验证、存档恢复验证或独立经济守恒验收。当前runner没有连续实体数/内存曲线，因此未证明内存稳定，也不能从退出RID告警判断运行期泄漏。未重编译：已加载Debug DLL时间23:07:58晚于检查到的源文件修改；时间戳是构建新鲜度检查，不是可重现构建证明。

## 复现与原始证据

DLL SHA256：073E07C04120AD45B55C9D1C0ECC21B1B22D3D56F58F39C3F5863471ED861135。
Git HEAD：deddb48547816140655aa2ac3c037fada930fb8a；工作树存在用户迁移改动，未还原或提交。

```powershell
& 'D:/Godot/Godot_v4.6.2-stable_win64.exe/Godot_v4.6.2-stable_win64_console.exe' --headless --path Project/project-keynes res://tests/authority_stage_c_client_runner.tscn -- mode=ACTIVE seed=1735228708 width=60 height=40 foreign_count=5 speed=50 warmup_seconds=5 record_seconds=120 output_dir=D:/Godot/ProjectKeynes/Project.Keynes/tmp/codex_soak_60x40_default120 require_owned_state=true min_native_days_per_second=49 max_commit_gap_ms=1000
```

原始文件：同目录下codex_soak_60x40_20260919/与codex_soak_60x40_default120/的session.json、frame_samples.csv、perf.csv、analysis.json；对应.log在其上级tmp。分析脚本为tmp/analyze_current_soak.py。录制走正式年度自动存档路径，会写应用autosave槽位。
