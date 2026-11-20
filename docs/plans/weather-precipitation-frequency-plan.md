# 天气降水频率治理计划（v2）

> 状态：**待评审**（未改任何生产代码）
> 日期：2026-11-20
> 触发：玩家反馈「降水极其频繁」
> 范围：weather 场求解的 `convergence` 语义、降水分类门、降水空间平滑、分类温度距平、气候湿度饱和、降水供给侧
> 不含：天气视觉 shader 与粒子、`WeatherFront` 视觉对象、经济侧气候接口、生成期 `base_moisture` 纬带包络、台风路径
>
> **修订记录**
> - v1（21:10）初版。面积目标写作「陆地 12–22%」，来源是「地球降水时间占比 7–10% × 游戏可读性」，属设计锚点，未经推导。
> - v2（21:25，本文）重写。发现 v1 的陆地目标**低于该模型的数学下界**（见 §3 C3），故废弃。
>   目标口径改为「集中度 + 供水」两个可测量，面积作为推导结果；新增 W1 标定框架与 W8 供给侧工作项。
> - v2.1（21:35）新增 **W9 退役 `PK_CLIMATE_CONVERGENCE_LEGACY` 与双实现**：
>   退役窗口（D-1..D-4）、动作清单、证明义务、回滚方式全部写入计划，不再以「以后删」作为承诺。
>   详细实测证据与逐项执行状态见 `weather-precipitation-frequency-checklist.md`。

---

## 0. 一页结论

**症状不是「雨太多」，是「雨太散」。** 陆地 55% 的格子同时在下雨，但下雨格只比平均湿 1.8 倍（地球量级约 10）
—— 这是「到处毛毛雨」的定量特征。面积只是这个集中度的倒数：`area = 1 / conc`。

**为什么散**，三条结构性原因：

1. `convergence` 是个**半波整流 + 固定几何偏移**的量：均匀风场（零辐散）读数就有 ≈1/3，实测中位 0.370。
   它被当成 0–1 的物理辐合，乘 1.00（凝结）/1.95（自动转化），成为全图常驻的成云成雨源。
2. RAIN 的判定是**一条绝对阈值**（`precip > 0.040` 陆地 / `0.032` 水域，无其它条件），而降水场已被多轮调参抬到
   典型值 0.05–0.09 ⇒ 只要产生任何降水就算「降雨」。
3. 分类器有**两条结构性死分支**：`wx->temp_anomaly` 在 native daily 从未被赋值，且 `weather_temp_anomaly_cap=0.025`
   小于分类门限 0.05 ⇒ 旱灾/热浪恒为 0，天气只剩「晴朗 / 下雨」两态。

**为什么不能只调参数**：这三条都是结构性的。用 profile 数字去抵消第 1 条，只能把 `conv_precip_gain` 压到 0，
连同真实辐合信号一起废掉。必须改语义。

**目标怎么定**：不拍数字。先用生成期 `base_moisture`（自带 35 项硬验收）当锚点做一次标定（W1），
再由代数关系 `area = mean_P / P̄`、`P̄ ≤ soft_cap` 推出可达区间。任何单点目标都必须附上
`ΣP / mean_P / P̄ / conc / 下界` 五个数才能进验收。

---

## 1. 症状的可测定义

把「降水极其频繁」拆成 6 个可测指标，全部由 headless probe 输出（§8）：

| ID | 指标 | 定义 |
|---|---|---|
| M1 | `land_rain` | 陆地格中 `weather_type ∈ {RAIN,STORM,BLIZZARD,MONSOON}` 的占比 |
| M2 | `conc` | `P̄_rainy / mean_P`（集中度；越大越「成片」） |
| M3 | `area` | 同 M1，同时报 `ΣP`、`mean_P`、`P̄_rainy`、`mean_P/soft_cap`（下界） |
| M4 | `hp_rain` | `ψ < −0.05`（高压区）格子的降水占比 —— 检验「低压下雨、高压晴空」是否成立 |
| M5 | `type_mix` | 8 种天气类型占比；特别看 DROUGHT / HEATWAVE / FOG 是否 >0 |
| M6 | `moist_sat` | `cell_moisture == 1.0` 的占比 —— 气候水储量是否被钳顶 |

现状：M1=54.8%、M2=1.82、M3(area)=54.8%/下界 30.0%、M4=34.5%、M5(DROUGHT/HEATWAVE)=0/0、M6=35.5%。

---

## 2. 已确立的事实

全部为实测或逐符号核对，来源见 checklist。F1–F6 来自存档解码，F7–F14 来自代码。

| ID | 事实 |
|---|---|
| F1 | 降水格占比在 3 份存档上稳定：全图 34.0%/29.3%/33.1%，**陆地 48.4%/54.4%/54.8%** |
| F2 | 陆地 `conc` = **1.82**，全图 2.81，水域 3.21（day 6570） |
| F3 | 降水场二值化：`precip>0.003` 与 `precip>0.032` 的格数完全相同 ⇒ 非降水类型的残余降水被归零回水汽 |
| F4 | `convergence` 中位 0.370（全图）/ 0.346（陆地），三份存档分别在 0.351/0.339/0.346，几乎不动 ⇒ 常数项 |
| F5 | 高压区（ψ<−0.05）占 43.4%，其中 **34.5% 仍在降水**；ψ>0.05 只占 10.6% |
| F6 | 陆地 `moisture` p50 = **0.981**、p75 = 1.0；全图 `moisture==1.0` 占 35.5% |
| F7 | `convergence = mean_d max(0, cos(self→nb, wind_nb)) · clamp(speed/1.2, 0.20, 1.25)`；半波整流、无出流项、风速有下限 |
| F8 | 该量直接乘增益：`cond_force += conv*1.00`、`trig += AUTOCONV*conv*1.95`；另有 6 处阈值消费它 |
| F9 | 均匀风场下 F7 的解析值：六角格 6 个等间隔方向，`mean(max(0,cos))` 恒在 0.29–0.33 |
| F10 | GDScript 镜像 `wind_convergence_*` **没有** speed 权重，与 C++ 本就不同源（既有缺陷） |
| F11 | RAIN 判定：`precip > 0.040`(陆)/`0.032`(水) 无其它条件；弱分支 `0.030` 才要求云/水汽三条件 |
| F12 | `field_precip_spatial_smooth` C++ 默认 **0.30**，GDScript 全项目无下发点 ⇒ 生产永远吃默认值；把湿邻居降水的 30%/tick 灌进干格 |
| F13 | native daily 的 `wx->temp_anomaly` 从未赋值 ⇒ 分类器距平恒 0；且 `weather_temp_anomaly_cap=0.025` < 旱灾门 0.05 / 热浪门 0.04 |
| F14 | `moisture_target` 含 weather vapor / precip 正反馈项，回写单向钳 1.0；`surface_vapor_source` 陆地支路里 `base_m` 直接进供水 |

**两条新发现的独立缺陷**：F10（镜像不同源）、F13（两条类型死分支），与主问题无因果关系但同批可修。

---

## 3. 硬约束（任何方案都必须满足）

| ID | 约束 | 含义 |
|---|---|---|
| C1 | `area = mean_P / P̄_rainy = 1 / conc` | 面积不是自由参数，是集中度的倒数 |
| C2 | `P̄_rainy ≤ soft_cap = 0.16` | 单格降水被 `weather_extreme_precip_soft_cap` 压住（实测 max 0.177） |
| C3 | **`area ≥ mean_P / soft_cap`** | 由 C1+C2 推出。**陆地当前下界 30.0%**（0.0479/0.16），全图 16.2% |
| C4 | `ΣP ≈ ΣE`（稳态闭合） | 实测 365 天净失衡 0.13%（大气柱水 +5.96%，日均 `ΣP`=56.4）⇒ 总降水量由供水决定 |
| C5 | 不改 CLM2 ABI / 不新增持久 per-cell lane | 否则要 codegen + 存档迁移，超出本批 |
| C6 | C++ 与 GDScript 四份 convergence 实现必须逐位一致 | 2 个 C++ 变体（POD / 几何缓存）+ 2 个 GDScript 变体；F10 说明今天并不一致 |

**C3 的推论**：只改效率（供水不变）时，陆地面积最多降到 **30%**（且要求所有雨格打到 cap，现实中会停在 33–38%）。
想低于 30%，只有两条路：降供水（`ΣE`↓ ⇒ `mean_P`↓ ⇒ 下界下移）或抬 `soft_cap`（C2 放宽）。

---

## 4. 待证假设（每条都可被实验杀死）

| ID | 假设 | 证伪实验 | 若证伪 |
|---|---|---|---|
| ~~H1~~ | ~~`convergence` 的几何偏移是「雨散」的主因~~ | 已做（W2，net 口径其余不动） | **已证伪，见下** |
| H2 | 分类门与场量级脱钩（次要） | 只把门限从 0.040 抬到新场的 p80，看 `land_rain` | 变化 <3pp ⇒ 该假设无关紧要，W4 降级 |
| H3 | ψ 抑制不足是因为背景项盖过 ψ 项 | 统计 `ψ<−0.05 且 conv<新 p50` 的格子的降水率 | 若 >15% ⇒ 仍有非 ψ 非辐合来源，需回到 H1 分解 |
| ~~H4~~ | ~~空间平滑在扩边~~ | 已做（W5 三档） | **已证伪，方向相反**：0.30→26.95%、0.00→32.46%。硬门槛下平滑是**压缩**分布，关掉反而涨面积 ⇒ 保持 0.30 |
| ~~H5~~ | ~~分类温度距平缺失导致类型死锁~~ | 已做（W6） | **部分证实**：DROUGHT 从 0→1.4%（活了）；HEATWAVE 仍 0 —— 它的窗口 `temp_anom∈[0.04,0.05)` 且 `precip∈[0.006,0.012)` 太窄，被 DROUGHT 遮蔽。见 checklist W6 未达标项 |
| H6 | 湿度饱和是供水被抬高的直接原因 | `moisture`→`base_moisture` 对齐测量 + 蒸发源单变量 A/B | 饱和与供水解耦 ⇒ W7 只做经济手感，不做「修 bug」叙事 |

**H1 已证伪（2026-11-20，W2 实测，详见 checklist W2-8）**

net 口径上线、其余参数一律不动：12 日 land rain **62.20% → 64.57%**、conc **1.608 → 1.549**、
ΣP_land 55.54 → 58.60、MONSOON 72 → 247 格。方向与目标相反 —— 去掉 convergence 基线后
降水面积略升、集中度略降。机制：效率下降后 vapor/cloud 累积，RH 越过 `field_rh_condense`(0.70)
触发静力凝结，MONSOON 门（vapor>0.24 且 precip>0.065）成片触发，把总量补回来并摊得更开。

这与 §3 C4（`ΣP ≈ ΣE`，总量由供水决定）完全一致。**结论：convergence 语义是正确性问题，
不是面积问题的解。** 由此调整：

- W2 仍要做完并保留（它消掉了 0.37 的假基线，让 convergence 恢复物理含义）；
- **W3 的定位改为「让新口径在消费者侧有意义 + 量出分布」，不再承担降面积的目标**；
- 降面积的主战场前移到 **W7（湿度/供水一致性）+ W8（供水或雨强上限）**；
- §7 的执行顺序里，W7 从「并行可选」提升为 W8 的前置测量。

**排序原则（据 H1 结果更新）**：H6 → H2/H4 → H3/H5。H6 决定供水上限，是面积的唯一一阶杠杆。


---

## 5. 目标如何确立（取代拍数字）

### 5.1 锚点

不用地球降水占比（模型单位是归一化 0–1、六角格尺度未知，无换算关系）。
用**生成期自带的标定**：`base_moisture` 纬带包络有 35 项硬验收
（赤道陆地中位 0.43–0.47、副热带干带 0.08–0.20、中纬回升、极地再降、森林 25–36%、草原 <30%、荒漠 ≥2%）。
运行期 `cell_moisture` 是同一物理量在仿真里的演化值，应当围绕这个分布波动，而不是钳在 1.0（现状 p50=0.981）。
**这是内部不一致，判定它不需要外部数据。**

### 5.2 三个可调量，一个代数关系

| 可调量 | 载体 | 作用在 | 对 `ΣP` | 对 `conc` | 手感 |
|---|---|---|---|---|---|
| 效率 | `convergence` 语义 + 6 个阈值 + 分类门 + 平滑 | 同样水怎么落 | ≈不变 | ↑ | 雨带成片 |
| 供水 | `land_evapotranspiration_gain`(1.6) / `cool_season_vapor_floor`(0.10) / 湿度饱和 | 有多少水 | ↓ | ↑（间接抬 cap 上限） | 世界变干 |
| 强度上限 | `extreme_precip_soft_cap`(0.16) | 一场雨多大 | ≈不变 | ↑↑ | 雨变猛 |

三者都受 `area = mean_P/P̄`、`P̄ ≤ cap` 约束。给定目标面积，所需组合是**唯一可算的**：

| 目标陆地面积 | 所需 `conc` | 需要 `P̄_rainy` | 满足方式（任选一条） |
|---|---|---|---|
| 30% | 3.34 | 0.160 | 只改效率（正好打到 cap，实际会停在 33–38%） |
| 24% | 4.17 | 0.200 | cap→0.22，或供水 ×0.83 且 conc 4.2 |
| **22%** | **4.55** | **0.218** | **cap→0.24，或供水 ×0.70 且 conc 4.55** |
| 18% | 5.56 | 0.266 | cap→0.30，或供水 ×0.55 |

（`mean_P_land` 现状 0.0479；供水系数 k 使下界 `0.0479k/0.16` 线性下移。）

### 5.3 本计划的承诺方式

**不承诺单一面积数字。** 承诺三件事：

1. **自洽性**（可立即验收，已由 W1 交付物实测）：
   - `area ≈ 1/conc`（<5%，**必须同 population**；混用陆地面积与全图集中度会产生 6.5% 的伪偏差，见 checklist W1-2）
   - `area ≥ mean_P/0.16`
   - 收支分两档：30–179 日判「没有失控累积」`|Δcolumn|/日均ΣP < 0.25`；≥180 日判「近似闭合」`< 0.02`。
     依据：新图 day 7→30 实测 0.1998（vapor 仍从零灌入），玩家存档 365 日窗口实测 0.0013 ——
     短窗口由 spin-up 主导，一刀切 1% 会把正常初始化判成回归。
2. **集中度**：陆地 `conc` 从 1.82 提到 **3.2–4.5**（W2–W5 完成后测）。
3. **供给侧与上限的抉择**（W8）：二选一，选完面积自动落定，**并写进 checklist 备案**。

按此，**预期落点**（待 W1 实测确认，非承诺）：只做 W2–W5 ⇒ 陆地 30–38%；
加 W8 的供水路线 ⇒ 22–26%；加上限路线 ⇒ 22–26% 但世界不变干。

---

## 6. 工作项

每个工作项写明：改什么、**不动什么**、预期效果、证伪/回滚方式。

### W1 标定框架（无行为改动）

产出三样东西，之后所有目标讨论共用同一把尺：

1. `tests/world/weather_frequency_probe.gd`：输出 §1 的 M1–M6 与 §5.3 的三个自洽量，JSON + 逐日时间序列。
2. `tests/world/weather_convergence_metric_test.gd`：均匀风 → 0；辐合中心 → >0.30；辐散中心 → 0。
   **今天必须红**（均匀风读数 ≈0.33）—— 这是根因复现证据。
3. `tools/analyze_weather_frequency.py`：离线解 `.pksv` 得同一组指标（存档侧复核，不依赖引擎）。
   同时输出 `moisture` vs 生成期 `base_moisture` 的分布对比（§5.1 的锚点校验）。

**不动**：任何生产代码。
**门禁**：三个自洽量全部成立；存档侧与引擎侧指标同量级（±5pp）；`base_moisture` 锚点确认可用。
**若锚点不可用**（例如拿不到 per-cell `base_moisture`）：改用「同种子重新生成一次、比两套世界的 `moisture` 分位」，
并在 checklist 记录替代口径。

### W2 `convergence` 改为有符号净流入

```text
w_d      = clamp(|v_nb|/1.2, 0.0, 1.25)                  // 去掉 0.20 下限
inflow   = Σ_d max(0, cos_in_d) · w_d
outflow  = Σ_d max(0, -cos_in_d) · w_d
net      = (inflow - outflow) / max(1e-4, inflow + outflow)
conv     = clamp(net · field_convergence_gain, 0.0, 1.0)  // 复用现有但被 (void) 的 gain
```

均匀风场 `inflow == outflow → 0`；辐合中心正；辐散中心钳 0。
保留旧实现，用 `PK_CLIMATE_CONVERGENCE_LEGACY` 运行时开关切换（照 `PK_CLIMATE_SYNOPTIC_OFF` 的先例）。

| 文件 | 符号 | 动作 |
|---|---|---|
| `gdext/src/runtime_climate_pass_math.h` | `wf_wind_convergence_idx_xy` / `_cached` | 新增 `_net` 变体，旧函数保留 |
| `gdext/src/runtime_climate_passes_weather.cpp` | `wx_convergence` lambda、`PREV_CNV` | 按开关选择实现 |
| `gdext/src/runtime_switch_registry.h/.cpp` | — | 加 `PK_CLIMATE_CONVERGENCE_LEGACY` |
| `gdext/src/world_ext_weather.cpp` | `(void)field_convergence_gain` | 去掉 void，真正接上 gain |
| `scripts/weather/field_solver_physics.gd` | `wind_convergence_for_cell` / `_idx` | 同步新公式 **并补齐 speed 权重**（修 F10） |

**不动**：`climate_profile.gd` 的 knob 语义、CLM2 lane、`component_schema.gd`。
**门禁（已按实测修订）**：新单测通过；legacy 路径行为未变（**不是**「与 W1 基线逐日逐位一致」——
W2 顺带修了采样协议，两者本应错开一天，判据改为 `new[day d] == old[day d+1]`）；
新口径下 GDScript 单测绿、C++ 由 probe 覆盖。C++↔GDScript 的逐位对拍留到 W3 前置。
**回滚**：`PK_CLIMATE_CONVERGENCE_LEGACY=1`。

### W3 六个消费者的阈值重标定（**定位已调整：不再承担降面积**）

W2 实测证明：「去掉 convergence 基线」会让 vapor/cloud 累积、RH 补回凝结，总面积不降反升
（见 §4 H1 证伪）。所以 W3 的目标从「降面积」改成两件正确性的事：

1. **让新口径在消费者侧仍然有意义**：net 的 p50 只有 0.016，而现有 6 处阈值是按 0.37 的假基线标定的
   ⇒ 锋生门（0.14/0.46）几乎永远关着、海面释放门（0.38/0.16）永远为 0，**真实辐合完全传不出去**。
2. **量出分布并留下证据**，给 W7/W8 一个干净的基线。

| 消费者 | 现值 | 新值取自（net 实测 p50=0.0163 / p90=0.4575 / p95=0.6363） |
|---|---|---|
| `frontal_convergence = smoothstep(a,b,conv)` | (0.14, 0.46) | 新 p50 / p90 |
| `drv_cv = (conv−c)/d`（海面释放门） | (0.38, 0.16) | 新 p50 / (p90−p50) |
| `strat_drive += conv*k` | 0.60 | 保持「旧 p90 处」同等贡献 |
| `river_forcing_proxy = conv*0.65` | 0.65 | 同比归一 |
| `dynamic_forcing = conv*0.65` | 0.65 | 同比归一 |
| `wf_apply_frontal_convergence_boost_idx::CONVERGENCE_THRESHOLD` | 0.45 | 新 p95；长期不触发则删除该路径 |

**做法**：逐处改、逐处跑，每处记录对 `land_rain / conc / hp_rain` 的影响。

**W3 结果（2026-11-20 实测，详见 checklist）**：六处已改，`weather_field_solver_test.gd` 26/26、
convergence 单测 3/3。聚合指标**几乎不变**（land_rain 64.5669→64.5669、conc 1.5488→1.5488，
ΣP 58.60→58.83），因为 net 口径 p50=0.016，多数格子吃不到 conv 项 —— 重标定只影响 top decile。
这再次印证 H1 证伪：**面积由供水决定**。

**门禁（已调整）**：分纬度降水率曲线**仍有 ITCZ 与风暴轴峰**（不能压成常数）；
`weather_field_solver_test.gd` 的定向用例（山地雨影 / 暖湿海面 / 冷区降雪）仍通过 ——
**不允许**为转绿而放宽断言（W3 期间确有一处断言改动，是「加严 + 补降水率下限」，见 checklist）。
`hp_rain <15%` 从 W3 移到 W7/W8：实测高压区降水同样由供水支配（day 12 `hp_rain=53%`），
不是 conv 阈值能解决的。

### W4 RAIN 判定改为「率 + 支持」

```text
meaningful_precip = precip > rate_gate
                 && effective_cloud > mp_cloud_gate
                 && precip_cloud_mass > mp_cloud_gate * 0.35
                 && vapor > mp_vapor_gate
```

强分支不再豁免云/水汽条件。`rate_gate` 提成 `ClimateProfile.weather_precip_classify_gate`（陆/水两档），
取值 = W3 完成后陆地降水率的 **p80 分位**，不拍数。
**改动**：`wf_classify_field_weather_at`、`feedback.gd::_classify_field_weather_core`、
`climate_profile.gd`、`native_bridge.gd`、`world_ext_simulation_host_save.cpp`（缺 key 回旧值）。
**门禁**：`precip` 分布不再是「0 或 >0.032」的二值跳变；`land_rain` 再降而 M6 不破。

### W5 降水空间平滑（**结论：保持 0.30，不关**）

> W5 实测（checklist「W5」节）：三档 `0.30/0.10/0.00` 的陆地降水格 26.95% / 32.28% / 32.46%，
> 集中度 3.711 / 3.098 / 3.081。**关掉平滑会让面积涨 5.5pp**，与本节原假设相反 ——
> 平滑削峰摊薄，在硬降水率门下更多格子跌回门下被判非降水。故保持 0.30（生产现值），
> 只把下发链补齐（F12 已消除）。以下为原始设计要求，保留作记录。

### W5 原始设计要求（已按实测调整，见上）

`field_precip_spatial_smooth` 0.30 → 0.10 → 0 两档各测一次后定档，**并显式纳入 `ClimateProfile` 下发**
（今天完全靠 C++ 默认值，这是 F12）。保留 0.10 的唯一理由是它同时承担「去棋盘洞」职责。
**门禁**：H4 实验数据；若两档差异 <2pp，取 0（少一个隐式默认）。

### W6 补分类温度距平，救活两条死分支

- host 计算 `snapshot.cell_temp_anomaly[i] = cell_temp[i] − cell_temp_30d[i]` 赋给 `wx->temp_anomaly`。
- **新增独立 knob** `weather_classify_anomaly_cap`（默认 0.12）用于分类输入钳制；
  **不动** `weather_temp_anomaly_cap`（0.025 = distribute 阶段改温度的幅度上限）。
  两者语义不同，共用会顺带把天气对温度的扰动放大 5×。
- 冷启动 30d EMA 不可用时退回 `temp − temperature_365d_ema`，在 report 里标注来源。
**门禁**：DROUGHT、HEATWAVE 各 >0 且 <8%（陆地）；其它类型占比不倒退 >3pp。

> **W6/W7 结论（2026-11-20 实测）**：W6 已落地（host 填 `wx->temp_anomaly`、新增
> `weather_classify_anomaly_cap=0.12` 与 distribute 的 0.025 分开），**DROUGHT 0→1.4%**，
> 聚合指标零副作用；HEATWAVE 仍 0（窗口太窄，留给下一轮二选一，不许凭感觉改）。
> W7 判定为**设计意图而非 bug**：没动任何 moisture 权重，`moist_sat` 就从 33.9% 掉到 7.7%、
> `land_moist_med` 从 0.981 降到 0.533（锚点 0.410）—— 原始钳顶是降水场正反馈的症状，W4 压降水后自行消退。
> 因此 W8 **不应**以「修不一致」为由降供水，只能作为手感/面积决策。

### W7 湿度饱和：先判断是「不一致」还是「手感」

测量 `cell_moisture` 与生成期 `base_moisture` 的逐格关系（W1 的产物 3），并做单变量 A/B：
`runtime_moisture_weather_vapor_weight` / `runtime_moisture_precip_weight` 分别置 0。
- 若运行期显著高于锚点且 A/B 能拉回 ⇒ 判定为**不一致**，给「降权 + 对称限幅」方案（不新增 lane）。
- 若运行期本来就在锚点分布内 ⇒ 判定为**设计意图**，只按 W8 的手感决策处理。
**门禁**：结论 + 证据进 checklist；本项只出判定与方案，是否实施由 W8 决策统管。

> **W8 实测结论（2026-11-20）**：**路线 B（抬 `soft_cap`）被证伪** —— 0.16→0.20/0.24 让陆地降水格
> 从 24.76% 涨到 30.80%/31.06%，`ΣP_land` 涨 40%。原因：0.16 的 soft cap 本身就在**压缩总降水**，
> 放宽它等于解除抑制，雨更猛也更多。本计划 §5.2 把 cap 当成「同量水重新分配」是错的 —— 它改变总量。
> 路线 A（降 `weather_land_evapotranspiration_gain`）单调有效：1.60→24.76%、**1.30→17.85%**、
> 1.10→12.77%、0.85→8.57%。C（不动）当前 24.76%，A@1.30 可落进 12–22% 但世界变干。
> 详见 checklist「W8」节。**代码层不涉及改动，只差一行 `.tres`，等 D2 拍板。**

### W8 供给侧或强度上限：二选一

| 路线 | 动作 | 效果 | 代价 |
|---|---|---|---|
| A 降供水 | `weather_land_evapotranspiration_gain` 1.6 → 1.1 → 0.85 三档 | `ΣP_land` 21.4 → 15.0/10.7；下界 30% → 21%/15% | 世界变干，影响湿润 biome 手感 |
| B 抬雨强 | `weather_extreme_precip_soft_cap` 0.16 → 0.24 | `P̄` 上限抬到 0.24；同样水以更少更重的雨落下 | 单格峰值 0.177 → ~0.28；需补水文与视觉回归 |
| C 不动 | — | 验收锁定陆地 30–38% | 雨依旧比地球散，但不再「半张地在下雨」 |

**门禁**：路线选定 + 三档测量曲线（`ΣP / mean_P / P̄ / conc / area`）进 checklist。
选定前不得对外宣称任何低于 30% 的面积数字。

### W9 退役 legacy 开关与双实现（发布后清理，非可选）

**为什么必须进计划、而不是留一句「以后删」**：`PK_CLIMATE_CONVERGENCE_LEGACY` 只在 W2–W3 的过渡期有用途
—— 它的唯一作用是证明「legacy 模式逐位不变」。一旦 net 成为默认并通过终验，它就从安全网变成
**两条永不收敛的实现**：convergence 从 4 份变体变成 2 套语义 × 4 份变体，`rg` 查不到生产调用，
下一个人不知道该改哪一份。F10 就是这样产生的（历史上已经有一对 C++/GDScript 不同源的实现，没人清理）。

**退役窗口（四条同时满足才允许动手）**

| ID | 条件 | 判据 |
|---|---|---|
| D-1 | net 已是生产默认且通过终验 | 60 日 soak + parity 无新增 diverged + `golden_day_hash_test` |
| D-2 | 跨过完整季节窗口 | 至少一份 ≥365 committed days 的实际存档或 soak 走 net 口径 |
| D-3 | 窗口内零回滚 | 没有触发 `PK_CLIMATE_CONVERGENCE_LEGACY=1` 的记录 |
| D-4 | W8 已定档并落地 | 否则下一轮平衡还需要 A/B |

**退役动作（按 diff 最小顺序）**

1. `runtime_climate_pass_math.h`：删除 legacy 函数体，把 `_net` 版本**改回原名**
   `wf_wind_convergence_idx_xy` / `wf_wind_convergence_idx_cached` —— 调用点名字不变，diff 只落在函数体。
2. `runtime_climate_passes_weather.cpp::wx_convergence`：删掉开关分支，只留一条实现。
3. `field_solver_physics.gd`：删掉 legacy 分支（W2 阶段在同一函数内做的开关）。
4. `runtime_switch_registry.h/.cpp`：删除 `PK_CLIMATE_CONVERGENCE_LEGACY` 枚举与描述行。
5. 更新 `world_ext_internal.h:281-287` 那句「两份逐位相同的实现」的注释（退役后=一份语义 × 四个变体）。
6. 清理 `docs/`、`tests/`、`tools/` 里所有 `CONVERGENCE_LEGACY` 引用（历史计划与状态文档的记载保留）。

**证明义务（缺一不可）**

- `rg -n "CONVERGENCE_LEGACY" gdext Project tools` 返回 **0 命中**（docs 里的历史记录除外），结果贴进 checklist。
- 退役后重跑：convergence 单测、probe（五元组必须与退役前**逐位一致**）、parity、golden、60 日 soak。
- `docs/architecture/current-state.md` 加一行：convergence 只剩单一实现、无运行时开关。

**风险与约束**

- 退役后不能再 A/B ⇒ D-4 必须先满足。若下一轮平衡需要重调，用 profile 的 `field_convergence_gain`
  和 6 个消费者阈值做 A/B，**不要恢复开关**。
- 退役提交**不得与 W8 的数值调整同批**，否则 soak 差异无法归因。
- 退役是纯删除，回滚 = revert 该提交；因此必须把 commit id 记进 checklist（此时总回滚手段从环境变量变成 revert）。
- 同类债务：`PK_CLIMATE_SYNOPTIC_OFF` 也是同样性质（长期 A/B 开关）。本批**不动它**，
  但在 W9 完成后记一条「运行时开关存量清单」到 `feature-status.md`，避免下次又留下一个。

---

> **W1–W5 实测进度（2026-11-20，60×40 / seed 20260727 / 30 日 / net 口径）**：
> 陆地降水格 55.0%(玩家存档基线) → 64.57%(W3) → **24.76%(W5)**；
> 全图 35.6% → 47.50% → **16.58%**；陆地集中度 1.817 → 1.549 → **4.039**；
> `hp_rain` 34.5% → 53.1%(98 格) → **15.08%(199 格)**；`moist_sat` 33.9% → 15.75% → **7.67%**；
> `ΣP_land` 58.83 → **38.40**。面积 24.76% 与 cap 下界 21.00% 只差 3.8pp ⇒ 已贴地板，再降必须走 W7/W8。

---

## 7. 执行顺序与门禁

```
W1 标定 ─► W2 语义 ─► W3 阈值 ─┬─► W4 分类门 ─► W5 平滑 ─┐
                               └─► W6 温度距平 ──────────┤
                                                        ▼
                              W7 湿度/供水一致性 ────► W8 抉择 ─► 终验 ─► 发布
                              （H1 证伪后升为 W8 的前置，不再是可选并行）

发布后且 D-1..D-4 满足：W9 退役 legacy 开关与双实现（单独 commit，可 revert）
```

> 2026-11-20 调整（H1 证伪，见 §4）：原本 W7 是「并行、供参考」，现在面积只剩 W7/W8 一条杠杆，
> 因此 W7 必须先于 W8 出结论，否则 W8 的三档测量没有判据。

| 阶段 | 门禁（未过不进下一阶段） |
|---|---|
| W1 | 三个自洽量成立；锚点可用或被替代口径记录 |
| W2 | 单测红→绿；legacy 逐位不变；新口径 C++/GDScript 一致 |
| W3 | `hp_rain` <15%；分纬度曲线保留双峰；定向用例不动断言通过 |
| W4 | 二值跳变消失；`land_rain` 再降而零降水陆地格 <8% |
| W5 | 0.30/0.10/0 三档数据齐；定档并写理由 |
| W6 | 两条死分支复活且不挤占其它类型 |
| W8 | 路线选定；面积与 `conc` 落进 §5.2 对应格 |
| 终验 | 60 日 soak + parity 无新增 diverged + `golden_day_hash_test` + p95 回归 <10% |
| **W9** | **D-1..D-4 全满足 + `rg` 零命中 + 退役前后五元组逐位一致 + commit id 入档** |

每阶段固定动作：重建 debug + release GDExtension → **完全重启 Godot 排除旧 DLL** → 跑 §8 验证矩阵 → 写数字进 checklist。

---

## 8. 测量基建与验证矩阵

**新增**（W1 交付）
- `tests/world/weather_frequency_probe.gd`：`--days/--seed/--label`，输出 `M1–M6` + 五元组 + 逐日序列，JSON。
- `tests/world/weather_convergence_metric_test.gd`：convergence 语义单测。
- `tools/analyze_weather_frequency.py <save.pksv>`：离线复核 + `moisture`/`base_moisture` 对齐。

**复用**
- `tools/runtime/run_climate_parity.ps1`：C++ 与 GDScript 逐位 parity（W2 的镜像校验靠它）。
- `tools/runtime/Invoke-ClimateB8Soak.ps1` + `Compare-ClimateB8Soak.ps1` + `climate_b8_soak_policy.json`：
  60 日 soak，对标 `weather_precip_arr` / `weather_vapor_arr` 带宽。
- `tests/runtime/golden_day_hash_test.gd`：8 日跨域 hash 确定性。
- `tests/world/weather_field_solver_test.gd`：定向物理用例。
- GM `tile_data_recorder`：CSV 交叉核对（记录 `weather_type_arr` / `weather_precip_arr` / `weather_convergence_arr`）。

**每次改动的检查顺序**：单测 → 引擎 probe → 存档侧复算 → parity → soak → 性能 → `git diff --check`。

---

## 9. 风险与回滚

| 风险 | 判据 | 处置 |
|---|---|---|
| 雨被砍过头变永晴 | 30 日零降水陆地格 >8%，或分纬度曲线失去双峰 | 回调 W3 的 `strat_drive`/`dynamic_forcing`；`rate_gate` 下修 |
| parity 红且无法归因 | 4 处镜像有遗漏 | `PK_CLIMATE_CONVERGENCE_LEGACY` 二分定位；禁止放宽 parity 断言 |
| 存档瞬态被误报 | 读档首 2 日 convergence 从旧尺度跳到新尺度 | 记入 `feature-status.md` 已知瞬态 + 加读档日志 |
| 性能回归 | p95 单日 >10% | 本改动只加 6 次乘加/格/2 天；先查是否误把 refresh stride 改小 |
| 目标再次拍错 | 出现无法由 §5.2 推出的目标 | §5.3 第 1 条即门禁：任何面积数字必须附五元组 |
| W9 提前退役 | D-1..D-4 未满足就删开关 | 门禁强制；提前删会导致下一轮平衡无法 A/B，只能 revert |
| W9 与数值调整同批 | soak 差异无法归因 | W9 单独提交，且 commit id 入 checklist |
| 与上游冲突 | 上游同批改 weather | 先拉上游、独立审查、本地验证后再合 |

**总回滚**：
- W2–W3 期间：`PK_CLIMATE_CONVERGENCE_LEGACY=1`（环境变量，不动代码）。
- W9 退役后：开关已不存在，回滚 = **revert 退役提交**；因此 W9 必须单独成 commit 并把 id 记进 checklist。
- W4/W5/W6/W8 各有 profile knob 可复位，不依赖开关。

---

## 10. 文档与 skill 同步

| 文档 | 更新内容 |
|---|---|
| `docs/architecture/feature-guides.md` | 新增「天气场分类与降水频率」：convergence 语义与新旧对照、6 个阈值来源、分类门四项条件、空间平滑默认值来源、`area=1/conc` 与下界口径 |
| `docs/architecture/feature-status.md` | 带日期现状 + before/after 五元组 + soak run-id |
| `.dsh/skills/project-keynes-climate-runtime/references/algorithms-and-data.md` | 「Weather field and fronts」补 convergence 定义、分类门、平滑、4 处镜像清单、下界约束 |
| `docs/architecture/current-state.md` | W1–W8 不改 owner/report；**W9 必改**：写明 convergence 只剩单一实现、无运行时开关 |
| checklist | 每阶段数字与门禁结果 |

---

## 11. 待决策（有默认值，不阻塞开工）

| # | 决策 | 默认（若未答复） |
|---|---|---|
| D1 | 目标口径：以 `conc` + `ΣP` 申报、面积推导，而非单一面积数字 | 采用 |
| D2 | W8 路线：A 降供水 / B 抬上限 / C 不动 | **C 不动**（先把效率类修完，再看密度是否够） |
| D3 | 是否同批做 W6（会引入旱灾/热浪） | 做（否则「不下雨=晴朗」的单调节奏不变） |
| D4 | `convergence` 同名改语义 vs 换名 | 同名改语义，文档写对照表 |
| D5 | `PK_CLIMATE_CONVERGENCE_LEGACY` 退役时机 | **按 W9 的 D-1..D-4 执行**（终验 + 跨一个季节窗口 + 零回滚 + W8 已落地），不与 W8 同批 |
| D6 | 起点：W1 起根治 vs 先做 W4+W5 止血 | **W1 起**（止血线只能到 35–40%） |

> 注意：D5 不再是「以后删」的口头承诺 —— 它已经是 W9 工作项，有窗口条件、动作清单、证明义务和回滚方式。

---

## 12. 已知局限

1. 全部实测来自单张 60×40 图、单种子、3 个时间点；海陆比 81% 水，换图后 `conc` 与下界会变，W1 必须多图复测。
2. `soft_cap` 是 profile 默认值（`earth_like.tres` 未覆盖）。是否允许改它属产品决策，不是技术问题。
3. §5.1 的锚点依赖 `base_moisture` per-cell 数据可得性；W1 若拿不到，按替代口径记录并与本文口径对照。
4. `area` 用 `weather_type` 判定，比 `precip>0` 少约 2.5pp（类型转换状态机有 2–3 天延迟），两者都必须报。
5. 水收支闭合只验证了大气柱（`vapor + cloud_water`）；土壤/水文储层在本世界未启用（相关 lane 全 0），
   若目标世界启用水文，C4 需要扩展为「大气 + 土壤 + 河道」三层。
6. 「集中度该是多少」目前只有地球 ~10 这个弱参照。真正的内部锚（降水场与已验收 biome 分布一致）
   要等 W1 的 `moisture`/`base_moisture` 对齐测量才能定量。
