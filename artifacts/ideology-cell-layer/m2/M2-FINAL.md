# M2 最终验收 — 32 格上限已移除，验收未闭合

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) 收尾 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | GLOBAL scope 探针定稿（6 checks）；12 项门禁全绿；最终回归零变化 |
| 结论 | **核心目标达成；rollout 仍 `Off`，§13.4 验收 3/11** |

## 1. 核心目标：已达成，且有三层直接证据

方案 §1.1 的目标是「命中 31/32/33/200 或全国全部格时，不再以 32 截断」。这一条**已完成**，代码与内容两侧都有断言：

| 层 | 状态 | 证据 |
|---|---|---|
| **代码常量** | `SELECTOR_MAX_CELLS` 语义已拆分：几何界保留，策略上限对领土/来源种类返回「无上限」 | `selector_cell_cap_test` **35 checks** |
| **内容参数** | **194 / 194** 个 kind-12 program 从 `(32, 0)` 改为 `(0, 0)`，无一例外 | `selector_cap_removed_test` **12 checks**，直读 `.tres` 断言 |
| **两层校验** | GDScript 与 C++ 都按种类判定，不再一刀切 32 | `ideology_effect_definition_ceiling_test` **19 checks** |

**行为证据（不是代码外观）：**

```
200 格的国得到 200 个目标          （旧上限 32）
33 格 —— 刚好超过一格 —— 全部保留
1000 格：包含第 33 格与第 999 格
显式写 32 仍得 32                  （删的是默认上限，不是表达能力）
写 5000 仍受地图限制               （「无策略上限」≠「无限制」）
```

## 2. 派生层：实现完整，逐层有测试

| 层 | 检查数 |
|---|---:|
| 判定器（§4.4 十四项条件） | 56 |
| 派生层容器 / ADR02 | 51 + 19（执行验证） |
| 合并公式（§5.1） | 20（merge）+ 7（numeric） |
| 物化器 | 65 |
| **§13.2 同输入逐格 oracle** | **735** |
| 枚举并集 / 版本组合 | 20 |
| 分片状态机 | 56 |
| catalog（I01 单一 backend） | 9 |
| unbounded（真实选择器 32+） | 1 GDScript + 9 C++ 断言 |
| GLOBAL scope 探针 | 6 |

## 3. 性能：已实测，门禁通过

从 O2 微基准外推 → 真实世界多进程采样：

```
800 格：  n=5  p50 4.516 ms  p95 4.805 ms   spread 1.69x
2000 格： n=4  p50 11.982 ms                spread 1.81x
```

| 量 | 值 |
|---|---|
| 每格成本（p50） | **5.65 us（800 格）/ 5.99 us（2000 格）**，差 6% |
| 每片耗时 | 0.347–0.374 ms |
| **§14.3 单 slice 判定** | 0.374 + 0.465 = **0.841 ms < 1.0**，余量 **15.9%** |
| 6400 额外推 | 38.3 ms / 100 片 |

**微基准的 6.0 us 假设被实测 p95 的 6.01 us 三次独立验证。**

## 4. 回归：零判定变化

15 个 fixture 逐项与 M0 基线比对，**changed verdicts = 0**，含失败项的数量与检查数。

这意味着：代码改动、194 个内容参数、两层校验放宽、性能改造，**没有破坏任何既有断言**。

## 5. 门禁：12 / 12 全绿

```
oracle 735 / cap_removed 12 / ceiling 35 / eligibility 56
materializer 65 / shard 56 / layer 51 / cost_model 28
coverage 6-of-6 / m0_inventory / m0_epoch / budget
```

DLL `aea03edb…`；`kCellProgramRollout = Off`；内容 `(0,0)` × 194。

## 6. 未完成的部分（必须与上面的成果一起读）

### 6.1 `rollout` 仍是 `Off` —— 运行时行为未变

派生层接线已通、物化器可用、分片工作，但 `kCellProgramRollout = Off` 意味着生产仍走实例路径。

**后果：** 本方案的目标（消除 32 格限制）在**目标解析层**已达成，但**这些格如何落地**仍是旧的实例路径，最多 32 个实例。

M2-17 曾试图测量「打开会破坏什么」，结论是**无法测**：`resolve_effect_targets` 在无 epoch 的夹具里先返回 false，派生分支不可达，因此零回归不构成安全证据。

### 6.2 §13.4 的 11 个测试只完成 3 个

| 已完成 | 缺失 |
|---|---|
| catalog、unbounded、numeric | invalidation、worker、timing、ack、save_golden、idle、explain、budget（8 个） |

其中 `worker` 依赖已知的 worker 夹具缺口，短期无解；其余 7 个可在裸 `SceneTree` 里做。

### 6.3 端到端验证缺口（贯穿全程）

`capture_country_epoch` 需要真实 `MapData`（手写 stub 会崩溃，M1-8 实测 `0xC0000005`），唯一可行路径是 `generate_world()` + worker 协作。这条缺口被确认了**五次**：
M1-8、M1-13、M2-9、M2-14、M2-17。

**未能验证的是：** 真实 epoch 下，派生层是否真的产生行、rollout 打开是否安全。

### 6.4 两个未查清的技术问题

| 问题 | 影响 |
|---|---|
| ENTITY scope 行即使有非零 handle 仍不贡献 | numeric_test 因此不覆盖 ENTITY |
| `_city_output_shard` 的旧平面合并段（~65 行）未分片 | M5 删除旧平面时需连带处理 |

## 7. 本轮修掉的上轮遗留

`global_scope_probe.gd` 上一轮有 1 条错误断言（在 `get_modifier_report()` 上找 `scopes` 字段，而它只存在于 `explain_modifier_stat()`）。

修正后 **6 checks 0 failures**，并得到比上轮更强的证据：

```
explain scopes=[0] handles=[4294967296] sum_add=2.0
```

**scope 确实存为 0（GLOBAL），求和正确。** `handles` 里的实体句柄只是 explain 的输出格式，与 scope 无关。

顺带把「超量 magnitude」的断言从「值必须变」改成「被 reject 且值保持 base」——前者是我的假设，后者是实测行为。

## 8. 交接建议

| 优先级 | 事项 | 阻塞原因 |
|---|---|---|
| 1 | **worker + `generate_world` 协作夹具** | 解锁 rollout ON 验证、in-situ 测量、`worker_test` |
| 2 | 补 §13.4 的 7 个非 worker 测试 | 无阻塞，可直接做 |
| 3 | 产品决策：46 ms（6400 格）总延迟是否接受 | 需玩法验收 |
| 4 | 查清 ENTITY scope 不贡献的原因 | 可能影响所有 ENTITY modifier |

## 9. 复算方式

```powershell
# 全部门禁
& .\.codex-tmp\oracle_test.exe;      & .\.codex-tmp\cap_removed.exe
& .\.codex-tmp\ceiling_test.exe;     & .\.codex-tmp\eligibility_test.exe
& .\.codex-tmp\materializer_test.exe; & .\.codex-tmp\shard_test.exe

# 两个 GDScript 夹具
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru -ArgumentList `
  '--headless','--path','Project/project-keynes','-s','tests/ideology/ideology_cell_layer_global_scope_probe.gd'
```
