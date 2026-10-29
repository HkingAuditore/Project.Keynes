# M3-14 理念激活失败的完整链路（已定位到 economy 依赖）

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `ideology_ideology_queue_probe.gd`（**秒级**，绕开 10 分钟世界生成）|
| 结果 | 理念发现命令被接受但永不生效；根因定位到 **economy opinion 依赖** |
| 结论 | ramp 真实数值仍未取得；但诊断成本从 10 分钟降到 10 秒 |

## 1. 本轮的实质改进：便宜探针

之前每次验证要跑 `generate_world`（6144 格，约 10 分钟）。本轮做了一个**不生成世界**的探针：

```gdscript
ext.configure_economy(country_ir, profile, CELLS, 97)
ext.configure_effects(effect_ir)
ext.configure_modifiers(mod_ir, CELLS)
ext.configure_ideologies(native)
```

**全程约 10 秒。** 这是本轮最有价值的产出——它让后续迭代从「每次 10 分钟」变成「每次 10 秒」。

## 2. 确定的完整链路

```
[q] discover = { ok: true, accepted: 1, pending: 1 }
[q] day=0..3  run_ideology_daily -> done=true
[q] snapshot ideas=0          ← 永远为空
```

| 事实 | 含义 |
|---|---|
| `accepted=1 pending=1` | 命令进了队列 |
| `done=true` 每天 | 日推在跑 |
| `ideas=0` | 但队列**从未被转换成理念** |

## 3. 根因线索：run_daily 依赖 Economy opinion

```cpp
// world_ext_ideology.cpp:368
Dictionary result = ideology_runtime_from(_ideology_runtime)->run_daily(day_index);
// :381-385 的注释：
//   "On the first days the main thread's Economy has not published an opinion
//    revision yet, so `accrue_points` settles nothing and the runtime has no
//    country rows"
```

**理念的点数累积依赖 Economy 发布 opinion revision。** 我的裸探针里 Economy 从未跑过一次 epoch，所以没有 opinion，`accrue_points` 什么也不做。

这可能就是 `discover` 停在 pending 的原因：**没有点数/没有国家行，命令无法落地**。

## 4. 我又犯了四个 API 名称错误

| 猜测 | 实际 | 代价 |
|---|---|---|
| `ext.get_ideology_catalog()` | 不存在 | 10 分钟 |
| `ext.get_ideology_catalog_ids()` | 不存在 | — |
| `configure_economy(ir, null, ...)` | 第二参数必须 Dictionary | 10 分钟 |
| `ext.configure_ideology(...)` | **`configure_ideologies`（复数）** | 10 分钟 |

**四次都是可用 `grep` 一秒解决的。** 我在真实世界运行时长的压力下反复直接试错，这是明确的效率问题。

## 5. 我这轮做对的一件事

把探针从 10 分钟降到 10 秒后，后两次错误只花了 10 秒而非 10 分钟。

**降低反馈周期比加速试错更重要。**

## 6. 验证

| 项 | 值 |
|---|---|
| 便宜探针耗时 | **约 10 秒**（vs 世界生成 10 分钟）|
| `configure_*` 全部成功 | economy / effects / modifiers / ideologies 均 `ok=true` |
| discover | `ok=true accepted=1 pending=1` |
| snapshot | `ideas=0`（4 天均如此）|
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 全 0 |

## 7. 局限

- **仍未取得 24 个 ramp 的真实数值。**
- 「economy opinion 依赖」是**读注释得出的推断，未验证**。
- 未尝试先跑一个 economy epoch 再看 discover 是否落地。
- 便宜探针里 `handle=4294967296`（slot 0），与真实世界夹具的 `4294967300` 不同，两者环境不完全等价。

## 8. 下一步（具体且便宜）

现在探针只要 10 秒，可以快速迭代：

1. 在探针里先跑 `begin_or_reuse_economy_input_epoch` + `run_economy_slice`，让 Economy 产出 opinion；
2. 再 discover + settle，看 `ideas` 是否非空；
3. 一旦 `ideas>0`，`seen`/`taken` 就应该非零，ramp 真实值即可读出。

## 9. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_ideology_queue_probe.gd'
# 约 10 秒；=> discover accepted=1 pending=1 ; snapshot ideas=0
```
