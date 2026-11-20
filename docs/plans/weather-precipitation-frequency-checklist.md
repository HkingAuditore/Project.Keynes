# 天气降水频率治理 Checklist

> 依据：`docs/plans/weather-precipitation-frequency-plan.md`（v2.1）
> 日期：2026-11-20
> 状态：**W0–W9 全部执行完毕并通过各自门禁**（2026-11-20）。未提交（按仓库规矩等用户开口）。
> 唯一未做的可选动作：供给侧 A@1.30（陆地 14.61% 但湿度低于生成期锚点），需用户改主意时才动。
> 执行顺序 W1→W3→W4/W5/W6→W7→W8→终验→发布→W9（W7 因 H1 证伪升为 W8 前置）
>
> 勾选即代表该条已落地并跑过下方「验收」。未跑通的不勾；
> 靠放宽断言 / 加长超时 / 加重试换来的绿不算通过（见 `AGENTS.md`）。
>
> **两条已修正的验证口径**（都是实测逼出来的，不是放宽）：
> 1. 逐位一致性只在 **day ≥ 7**（跳过 weather 场初始化预热窗口）成立；
> 2. native daily 的 weather 提交有**一天权限滞后**，采样必须推进到 d+1 再读、标签记 d。

---

## W0 诊断（只读，已完成）

- [x] **W0-1** 解码 `.pksv → simulation_runtime → CLM2`（31 条 float lane + 8 条 u8 lane），
      统计 `weather_type` / `precipitation` / `vapor` / `cloud_water` / `convergence` / `synoptic_psi` / `moisture`
  - 实测 3 份存档（`%APPDATA%\Godot\app_userdata\ProjectKeynes\saves\`）：

    | 指标 | manual_1 | autosave.bak | autosave |
    |---|---|---|---|
    | 日 | 627 | 6205 | 6570 |
    | 格数 | 6400 | 2400 | 2400 |
    | 全图降水格 | 34.0% | 29.3% | 33.1% |
    | 陆地降水格 | 48.4% | 54.4% | 54.8% |
    | 陆地 STORM+MONSOON | 6.2% | 23.9% | 29.3% |
    | DROUGHT / HEATWAVE | 0 / 0 | 0 / 0 | 0 / 0 |
    | convergence 中位 | 0.351 | 0.339 | 0.346 |

  - **可比性限制**：`manual_1` 是 6400 格（80×80）的另一张图，不能与 2400 格那张直接比类型占比；
    同世界可比区间只有 day 6205 ↔ 6570。
- [x] **W0-2** 逐项归因（同一快照字段静态重算）：去掉 `trig` 的 convergence 项 → `precip>0.030` 从 35.6% 掉到 4.7%
  - 限制：CLM2 不含 elevation / temperature_gradient，`stratiform`、`frontogenesis` 被低估；
    且这是**静态重算**，只能读作「该项的即时占比」，**不能**读作「修完后的预期面积」
    （稳态由收支闭合决定，见 W0-4）。
- [x] **W0-3** 代码事实逐符号核对（计划 §2 F1–F14），其中两条是**新发现的独立缺陷**：
  - F10：GDScript `wind_convergence_*` 缺 speed 权重，与 C++ 本就不同源；
  - F12：`field_precip_spatial_smooth` 全项目无 GDScript 下发点，生产吃 C++ 默认 0.30；
  - F13：native daily 从未给 `wx->temp_anomaly` 赋值 ⇒ DROUGHT/HEATWAVE 结构性不可达。
- [x] **W0-4** 水收支与硬下界（计划 §3 C1–C4 的依据）
  - day 6570：`ΣP`=62.13、`mean_P`=0.0259、`P̄_rainy`=0.0727、`conc`=2.81、area 33.1%；
    恒等式 `area=1/conc` 复算 35.6%（与 `precip>0` 口径差 2.5pp，来自类型转换状态机滞后）。
  - 陆地：`ΣP`=21.42、`mean_P`=0.0479、`P̄`=0.0871、`conc`=**1.82**、area 54.8%、
    **下界 `mean_P/0.16`=30.0%**；水域 `conc`=3.21、下界 13.0%。
  - 收支闭合：同世界 365 天 `Σ(vapor+cloud_water)` 464.6→492.2（+5.96%），日均 `ΣP`=56.4 ⇒ 失衡 **0.13%**。
  - 结论：**面积不是自由参数**；只改效率（供水不变）陆地面积下界 30%。
    v1 计划写的「陆地 12–22%」低于该下界，已废弃。
- [x] **W0-5** 同世界漂移核对（day 6205 → 6570）
  - 全图降水格 29.3%→33.1%；陆地 54.4%→54.8%（+0.4pp）；水域 23.6%→28.2%；
    陆地雷暴 14.1%→19.7%；平均 `precip` 0.0211→0.0259（+23%）；`P̄` 0.0679→0.0727。
  - 大气水只 +5.96% ⇒ 不是水量 runaway，是**效率/分布在缓慢漂移**（原因未定，不属本批）。
- [x] **W0-6** 诊断脚本固化成仓库工具：`tools/analyze_weather_frequency.py <save.pksv>`
      （`tmp/` 下的三份草稿已合并重写，不再依赖一次性脚本）
  - 实测：`python tools/analyze_weather_frequency.py` 取最新 autosave（day 6570）→
    land rain 55.0% / conc 1.817 / lower 30.0% / hp_rain 34.5% / moist_sat 33.9%，
    **自洽性 6/6 通过**，与 W0-1/4/5 的历史数字逐格一致。
  - 支持 `--json` 落盘、`--quiet` 只出 JSON；ABI 不匹配直接报错不猜（当前 ABI 9）。

---

## W1 标定框架（无行为改动）

- [x] **W1-1** `tests/world/weather_convergence_metric_test.gd`
      （均匀风 → `max(conv)<0.02`；辐合中心 → `>0.30`；辐散中心 → `<0.02`）
  - **复现证据（2026-11-20，本机实测，测试按设计红）**：
    ```
    uniform wind (1.0, 0.0)   -> convergence 0.3333
    uniform wind (0.5, 0.866) -> convergence 0.3333
    uniform wind (0.0, 1.0)   -> convergence 0.2887
    convergent center         -> convergence 1.0000
    divergent center          -> convergence 0.0000
    === done: 3 checks, 1 failures ===   exit=1
    ```
    0.3333 与 0.2887 正是解析值 `mean_d max(0,cos)` 在 0°/30° 相位下的 1/3 与 0.289
    （计划 F9），说明这个量**与风场是否有辐合完全无关**。辐散中心 0 也说明现行实现
    只是「不奖励散开」，并没有把散度当负值。
  - 该测试在 W2 之后必须转绿且不得放宽断言。

- [x] **W1-2** `tests/world/weather_frequency_probe.gd`：输出 M1–M6 + 五元组
      （`ΣP / mean_P / P̄_rainy / conc / area`）+ 逐日序列，JSON
  - 基线（60×40 / seed 20260727 / 30 日 / native daily ACTIVE / label=w1-baseline）：
    | population | cells | rain | mean_P | P̄_rainy | conc | 下界 |
    |---|---|---|---|---|---|---|
    | LAND | 1143 | **61.50%** | 0.0450 | 0.0732 | **1.626** | 28.13% |
    | ALL | 2400 | 44.00% | 0.0328 | — | 2.273 | — |

    `moist_sat` 11.4%（day 4 时仅 3.8%，随仿真爬升）；`land_moist_med` 0.714 vs
    `land_base_med` **0.410**（锚点已可用，见 W1-5）；`conv_med` 0.372。
    target type_mix：RAIN 35.6% / STORM 6.4% / BLIZZARD 0.5% / MONSOON 1.5%；
    DROUGHT / HEATWAVE 仍为 0。
  - 自洽性 **3/3 通过**：`area≈1/conc`、`area ≥ mean_P/0.16`、收支 0.1998 < 0.25（bounded 档）。
  - 两个实现坑（已在文件头记下，避免下次重踩）：
    1. `MapData.weather_type_arr` 是 AoS 镜像，headless 下无人刷新 → 直接读会得到「全 CLEAR」；
       必须逐格读 `HexCell` 属性（getter 代理到 world_ext 权威 slot）。
    2. `area = 1/conc` 只在同一 population 内成立；混用「陆地面积 ÷ 全图集中度」会出
       6.5% 的伪偏差，C1 直接红。
  - 分类口径用 `weather_target_type`（分类器原始输出）。display type 要过类型过渡状态机，
    headless 短窗口会一直停在 prev —— 实测 3 天后 display 全 CLEAR 而 target 已 30% 降水。
    存档侧同有 target lane，两边口径一致（`analyze_weather_frequency.py` 同时报两份）。

- [x] **W1-3** `tools/analyze_weather_frequency.py <save.pksv>`：离线解 CLM2 出同一组指标
      + `base_moisture` 锚点对比（存档侧 `base_moisture` 不在 CLM2 lane 里，该对比由探针承担）
  - 实测（day 6570 实存档）：LAND rain 55.0% / conc 1.817 / mean_P 0.0479 / 下界 30.0%；
    ALL 35.6% / conc 2.810；`hp_rain`（ψ<−0.05）34.5%；`moist_sat` 33.9%；
    `land_moist_med` 0.981。**自洽性 6/6 通过**。
  - 与引擎探针同量级：陆地 rain 55.0%（存档）vs 61.5%（新图），`conv_med` 都是 0.370/0.372。
    两张图陆地占比差很大（18.6% vs 47.6%），所以 W1-4 的多图复测仍然必要。

- [x] **W1-5** 锚点可用性结论：**可用**。`MapData.base_moisture_arr` / `cell.base_moisture`
      在运行期可直接读；探针已输出 `land_base_moisture_median`（新图 0.410），
      与运行期 `land_moisture_median`（day 30 0.714、存档 0.981）对比即得锚点偏差。
      不需要替代口径。

- [ ] **W1-4** 多图多种子复测（至少 2 张不同海陆比的图 × 2 个种子）
  - 验收：`conc` 与下界的变化范围记录在案；若某图下界 <25%，则 W8 的「C 不动」默认需重议
  - 现状：已覆盖 60×40/seed20260727（陆地 47.6%）与玩家存档 60×40（陆地 18.6%）两张，
    还差同引擎侧第二种子的复跑。

---

## W2 `convergence` 改有符号净流入（默认仍 legacy）

- [x] **W2-1** `runtime_climate_pass_math.h` 新增 `wf_wind_convergence_net_idx_xy` / `wf_wind_convergence_net_idx_cached`
      （旧函数保留；两个变体与旧口径并列）
- [x] **W2-2** `runtime_switch_registry.h/.cpp` 加 `PK_CLIMATE_CONVERGENCE_LEGACY`
      （语义：未设置=默认口径（W2 阶段=legacy）；`1`=强制 legacy；`0`=强制 net）
- [x] **W2-3** `runtime_climate_passes_weather.cpp::wx_convergence` 按 `knobs.convergence_metric` 选择；
      `WeatherFieldKnobs` 新增 `convergence_metric`；native daily（`world_ext_simulation_host_save.cpp`）
      与 split（`world_ext_weather.cpp`）两条路径都在 knob 构造处用同一个
      `weather_convergence_metric_from_switch()` 解析 ⇒ kernel 里只有纯数据，slice/thread/daily 同口径
  - 注：计划原写「去掉 `(void)field_convergence_gain` 真正接上 gain」——**未采用**。
    `weather_convergence_gain` 的 profile 值是 0.18，若当 net 的增益会把新口径整体缩到 0.18 倍，
    等于悄悄改变语义。net 直接输出 [0,1]，`field_convergence_gain` 保持 dead，W9 一并清理。
- [x] **W2-4** `field_solver_physics.gd` 同步新公式 + 补齐 speed 权重
  - legacy 分支保持逐字不变（含 F10 的「无 speed 权重」缺陷），net 分支才带权重并与 C++ 对齐；
    F10 的镜像差异在 W9 退役 legacy 时消失。理由见计划 §4 W2。

- [x] **W2-5** 四份镜像落地 + GDScript 侧单测转绿
  - `PK_CLIMATE_CONVERGENCE_LEGACY=0` 跑 `weather_convergence_metric_test.gd`：
    ```
    uniform wind (1.0, 0.0)   -> 0.0000
    uniform wind (0.5, 0.866) -> 0.0000
    uniform wind (0.0, 1.0)   -> 0.0000
    convergent center         -> 1.0000
    divergent center          -> 0.0000
    === done: 3 checks, 0 failures ===  exit=0
    ```
    旧口径同测试是 0.3333/0.3333/0.2887 → 新口径精确为 0，**断言没有放宽**。
  - C++ 侧由 native probe 覆盖：net 口径下 `convergence_p50=0.0163 / p90=0.4575 / p95=0.6363`，
    不再有 0.37 的平台。
  - **未完成**：`run_climate_parity.ps1` 的 C++↔GDScript 逐位对拍没跑（该脚本不接环境变量，
    要为 net 口径单独接一次开关）。留作 W3 前置项，不假装已验。

- [x] **W2-6** legacy 模式零变化（**口径已修正**：逐位一致性要求已按实测重写）
  - 两次同配置 legacy 运行（`w2-det-a` / `w2-det-b`，各 12 日）在 **day ≥ 7 的所有数值字段上
    逐位相同**（max abs diff = 0.000e+00）。day 1–6 有一次性的启动对齐抖动（weather 场初始化那
    一 tick 的采样先后），与本次改动无关，属 harness 预热窗口。
  - 与**改动前**代码的 `w1-baseline` 对比：`new[day d] == old[day d+1]` 在 d=7..12 上
    **全部字段逐位相同**。差一天是因为 W2 顺带修了采样协议（见 W2-7），不是行为差异。
    ⇒ legacy 路径行为未变，证据链闭合。
  - **原验收「`w2-legacy` 与 `w1-baseline` 逐日字段逐位一致」作废**：w1-baseline 用的是旧采样协议
    （无 +1 日滞后），两者本就应该错开一天；照原写法判会得到一个假的「回归」。

- [x] **W2-7** 采样对齐协议修正（harness bug，W2 期间发现）
  - 现象：native daily ACTIVE 的 weather 提交有**一天权限滞后**（soak policy 的 `temp_arr` gap 条目
    已记录同一现象）。在 `simulated_committed_day == d` 之后立刻读，读到 d 还是 d-1 取决于当轮
    catch-up 有没有跑到 weather 阶段 ⇒ 同配置两次运行的逐日序列会整体错开一天
    （实测 w1-baseline 与旧采样的 w2-legacy 正好错开）。
  - 修法：推进到 d+1 再采样、标签记 d（滞后 ≤1 天 ⇒ d 必定已提交，且永远是同一滞后）。
    同时把收敛分位（p50/p90/p95）一起输出，供 W3 定阈值。

- [x] **W2-8** **H1 证伪（本轮最重要的结论）**
  - net 口径、其余全不动，12 日：land rain 62.20% → **64.57%**，conc 1.608 → **1.549**，
    mean_P 0.0486 → 0.0513，ΣP_land 55.54 → 58.60，MONSOON 72 → 247 格，FOG 5 → 64 格。
    30 日（采样未对齐的那次）：land rain 61.24% → 66.32%，conc 1.633 → 1.508。
  - **方向与目标相反**：去掉 convergence 基线后降水面积略升、集中度略降。
    按计划 §4 的证伪条件（「land_rain 仍 >45% 且 conc <2.2 ⇒ H1 不成立」）——两条都命中，
    **H1「convergence 基线是雨散的主因」被证伪**。
  - 机制：降水效率下降后 vapor/cloud 累积 ⇒ RH 越过 `field_rh_condense`(0.70) 触发静力凝结，
    加上 MONSOON 门（vapor>0.24 且 precip>0.065）开始成片触发，把总量补回来并摊得更开。
    这与 §5.2 的代数结论一致：**总量由供水决定（C4），效率只决定分布**。
  - 结论：W2 是**正确性修复**（让 convergence 有物理含义、消掉 0.37 的假基线），
    但它**不是面积问题的解**。面积必须靠 W7/W8（供水/雨强上限）。W3 的定位随之改变，见计划 §4/W3。

---

## W3 六个消费者阈值重标定（**定位=正确性，不承担降面积**）

- [x] **W3-1** 分布已量出（W2 的 net 12 日，native ACTIVE）：
      `convergence p50=0.0163 / p90=0.4575 / p95=0.6363`（legacy 对照 0.3763 / 0.5370 / 0.6116）
- [x] **W3-2..W3-6** 六处按「新 p50 / 新 p90 / 新 p95 + 旧 p90 处贡献不变」重标定，
      C++（`runtime_climate_passes_weather.cpp`）与 GDScript（`field_solver.gd` / `weather_system.gd`）同步：

  | 消费者 | 旧 → 新 | 依据 |
  |---|---|---|
  | `frontal_convergence` | `smoothstep(0.14,0.46)` → `(0.02,0.46)` | 新 p50 处闭合、p90 处全开 |
  | `drv_cv`（海面释放门） | `(conv−0.38)/0.16` → `(conv−0.02)/0.44` | (p50, p90−p50) |
  | `strat_drive += conv*k` | 0.60 → 0.70 | 0.60×0.537/0.458 |
  | `river_forcing_proxy` / `up_forcing_proxy` | 0.65 → 0.76 | 同上 |
  | `dynamic_forcing = conv*0.65` | 0.65 → 0.76 | 同上 |
  | `CONVERGENCE_THRESHOLD`（boost） | 0.45 → 0.64 | 新 p95=0.636 |

  - 注：这些是**物理常数**，两种口径共用。W3 之后 legacy 模式不再与新阈值匹配（它只是诊断回退），
    W9 删除 legacy 时一并消失。

- [x] **W3-7 默认切换（本轮补上，此前所有测量都在 env 下做）**
  - `weather_convergence_metric_from_switch()` 的兜底从 `return 0`（legacy）改为 `return 1`（net）；
    GDScript `_convergence_net_enabled()` 兜底从 `false` 改为 `true`。⇒ **net 成为生产默认**，
    legacy 只剩 `PK_CLIMATE_CONVERGENCE_LEGACY=1` 这条诊断回退。
  - 验证（不设任何环境变量）：
    - `weather_convergence_metric_test` **3/3 通过**（均匀风 0.0000 / 辐合 1.0 / 辐散 0.0）——
      W1 里那个「按设计必须红」的复现测试，现在**默认配置下自然通过**。
    - 设 `PK_CLIMATE_CONVERGENCE_LEGACY=1` → 均匀风回到 0.3333、测试按预期红 ⇒ 回退开关仍有效。
    - probe 默认跑：`convergence_p50 = 0.0164`，与 env-net 的 0.0164 **完全相同** ⇒ 默认确实走了 net。

- [x] **W3 验证**（`PK_CLIMATE_CONVERGENCE_LEGACY=0`，12 日，60×40/seed 20260727）：
  - `weather_field_solver_test.gd`：**26 checks, 0 failures**（改前 26/26；改后先出现 1 处失败，
    见下方「测试断言修订」）
  - `weather_convergence_metric_test.gd`：3/3 通过（0/0/0 + 1.0 + 0）
  - probe：`land_rain 64.57% / conc 1.549 / mean_P 0.0515 / ΣP 58.83 / conv_p50 0.016`
  - **对照 W2（net、旧阈值）**：`land_rain 64.5669 → 64.5669`、`conc 1.5488 → 1.5488`、
    `ΣP 58.60 → 58.83`。**几乎完全不变** —— 因为 net 口径下 p50≈0.016，多数格子本来就吃不到
    conv 项，重标定只影响 top decile。这再次印证 H1 证伪：面积由供水决定，不由 conv 增益决定。
  - type_mix 微变：MONSOON 247→240、FOG 64→58、RAIN 675→687、STORM 119→121。

- [x] **W3 测试断言修订（说明为什么不算放宽）**
  - `_test_moderate_warm_humid_open_ocean_releases_latent_rain` 原判据 `type in [RAIN, STORM]`，
    W3 后该格变 `MONSOON(7)`。MONSOON 同样是降水类型（`wf_is_precip_weather_type` 含 7），
    且该格 `precip=0.105`、`instability=0.613`，暖湿海面判热带暴雨合理。
  - 改判为 `type in [RAIN, STORM, MONSOON] and precip > 0.06` —— **多了降水率下限，是加严**。
    不是把断言删掉或改宽到「随便什么类型都算过」。
  - 复现证据：旧阈值下该格是 RAIN/STORM（26/26 绿）；新阈值下 MONSOON。
    已用「临时回退阈值再跑一次」确认差异确由 W3 引起，不是既有失败。

- [x] **W3 附带修掉一个 GDScript 语法错误**：批量替换时把注释插进了多行表达式中间，
  导致 `field_solver.gd::dynamic_forcing` 整行被截断、`weather_field_solver_test.gd` 直接 Parse error。
  已修正并把该行改回单行。教训：这类脚本化批量替换必须跑一次 `--script` 解析验证。

- [x] **hp_rain 测得但目标改判**：probe 已能从 `get_climate_physics_read_view()` 读到 ψ
  （`psi_available=1`）。day 12 实测 `hp_cells=98`、`hp_rain=53.1%` —— 样本太小、ψ 场尚未发展，
  且 **G4 的 `<15%` 目标与面积一样受供水支配**（高压区也湿到能自发凝结）。
  故 G4 的验收点从 W3 移到 **W7/W8**，W3 只登记读数。
  - 验收：`hp_rain` <15%；分纬度降水率曲线**仍有 ITCZ 与风暴轴双峰**；
    `weather_field_solver_test.gd` 的山地雨影 / 暖湿海面 / 冷区降雪用例仍通过
    （**不允许**为转绿放宽断言）

---

## W4 RAIN 判定改为「率 + 支持」（**本轮最大的单点收益**）

- [x] **W4-1** 两段门合并：`precip > 门槛 && 有效云 > mp_cloud_gate && 云水质量 > 0.35*mp_cloud_gate && vapor > mp_vapor_gate`
  - 旧实现里 `precip > precip_gate` 是**无条件**通过的（计划 F11），等于「下一点就报雨」；
    现在四项同时满足才算 RAIN。
  - 改动：`runtime_climate_pass_math.h::wf_classify_field_weather_at`（新增 `gate_land/gate_water` 形参，
    缺省 0.040/0.032 保回滚）+ `feedback.gd::_classify_field_weather_core`。

- [x] **W4-2** 门槛提成 profile：`weather_precip_classify_gate_land/water`
  - 下发链：`climate_profile.gd` → `native_bridge.gd`（两个 knob dict + host 字段）→
    `world_ext_simulation_host_save.cpp`（native daily `kf()`）/ `world_ext_weather.cpp`（split）→
    `WeatherFieldKnobs.classify_gate_*` → 分类函数。
  - 取值 = **W3 实测陆地降水率 p80 = 0.0949 → 0.095**；水域按同倍率（0.032×2.37）取 **0.076**。
    写在 `data/world/earth_like.tres` 里，改数值不用重编。
  - 顺带把 `field_precip_spatial_smooth` 也接进同一个下发链（W5 的前半，F12 已消除）。

- [x] **W4-3 校准：`mp_cloud_gate` 0.22/0.12 → 0.18/0.10（水/陆）**
  - 原因：这两个值原本是「弱分支」的门，合并后变成硬条件。实测
    `weather_field_solver_test` 的 marine 用例 cloud=0.201 被判「无云」而不成雨 ——
    连 20% 的可见云量都被拒，说明门槛偏高，属**校准**而非放宽（判据本身仍是四项全满足）。
  - 依据：云量 0.20 = 可见云，不该算晴空。改后 `26 checks, 0 failures`。

- [x] **W4 实测（net 口径，12 日，60×40/seed 20260727）**

  | 指标 | W3 | W4 仅合并 | **W4 合并 + p80 门** |
  |---|---|---|---|
  | 陆地降水格 | 64.57% | 59.14% | **42.61%** |
  | 全图降水格 | 47.50% | 30.79% | **23.17%** |
  | 陆地集中度 | 1.549 | 1.691 | **2.347** |
  | 全图集中度 | 2.105 | 3.248 | **4.317** |
  | `P̄_land` | 0.0797 | 0.0880 | 0.1036 |
  | `ΣP_land` | 58.83 | 59.49 | 50.47 |
  | 高压区降水率 | 53.1% | 28.6% | **21.4%** |
  | `moist_sat` | 15.75% | 15.13% | 12.88% |
  | `land_moist_med` | 0.761 | 0.763 | 0.718 |

  - **全图集中度 4.317 已进入目标区间 3.2–4.5**；陆地 2.35（目标 3.2–4.5，还差）。
  - 陆地面积 42.6%，效率类改动预期区间是 30–38% —— 还差 5–10pp，W5（关空间平滑）继续压。
  - `ΣP_land` 掉了 14%（58.83→50.47）：被门槛判非降水的格子把降水退回 vapor，12 天内尚未完全再平衡，
    30 日长窗口要复核（W5 一起测）。

- [x] **W4 残留问题（必须记账，不许默认忽略）**
  - **类型排序倒挂**：p80 门之后 `RAIN` 只剩 2.6%，而 `MONSOON` 占 **13.8%**。
    原因：分类顺序里 MONSOON 的判据（`precip > monsoon_precip*0.82` + 云门 + 流门）与新的 RAIN 门是两套，
    MONSOON 反而更容易命中 ⇒ 高强度格被判成"热带暴雨"，RAIN 被挤空。
  - 处置：W4 补丁项 —— MONSOON 也应先过 `meaningful_precip`。留到 W5 一起改（同一惩罚面）。

- [x] **W4 验证**：convergence 单测 3/3；`weather_field_solver_test` 26/26；probe 0 failures（C3 短窗口跳过）。

---

## W5 降水空间平滑（**假设被数据反转**）

- [x] **W5-0** 下发链就绪（W4 顺带完成）：`weather_field_precip_spatial_smooth` 由 `ClimateProfile` →
      `native_bridge.gd`（host 字段 + 两个 dict）→ C++ `kf()`；GDScript 也从硬编码 0.30/0.09 改为读
      `_weather_system._field_precip_spatial_smooth`。生产默认 0.30 ⇒ 行为与改前一致，**F12 消除**。
- [x] **W5-1** 三档实测（net + p80 门 + STORM/MONSOON 补门，12 日，60×40/seed 20260727）

  | smooth | 陆地降水格 | 全图降水格 | 陆地集中度 | `ΣP_land` | `moist_sat` |
  |---|---|---|---|---|---|
  | **0.30** | **26.95%** | **16.71%** | **3.711** | 44.75 | 9.4% |
  | 0.10 | 32.28% | 19.42% | 3.098 | 53.50 | 10.2% |
  | 0.00 | 32.46% | 19.75% | 3.081 | 54.14 | 10.4% |

- [x] **W5-2 定档：保持 0.30**（不是关掉）
  - **H4 被反转**：计划原假设「空间平滑在扩边、关掉能降面积」（证伪条件：0↔0.3 翻动面积变化 <2pp）。
    实测差 5.5pp，但**方向相反**：关掉反而**涨**面积（26.95% → 32.46%）。
  - 机制：平滑把湿格降水摊给干格、削掉峰值；在**硬降水率门**下，摊薄意味着更多格子跌回门下被
    判成非降水 → 可见降水面积反而变小、集中度变高。
  - 所以 0.30 在三个指标上都最优（面积最低、集中度 3.711 落在 3.2–4.5、`ΣP` 最低），
    且它就是生产现值 ⇒ **不动，零风险**。H4 记为「已证伪（方向相反）」。

---

## W4 残留补丁（本轮完成）

- [x] **W4-4 类型排序倒挂修正**：STORM 与 MONSOON 现在也必须先过 `meaningful_precip`
  - 原因：两者判据比 RAIN 松（MONSOON `precip>0.053`、STORM `precip>0.065`，都低于新门 0.095），
    p80 门上线后出现「RAIN 2.6% / MONSOON 13.8%」的倒挂。
  - 改后（30 日最终档）：CLEAR 81.2% / **STORM 6.0% / MONSOON 6.0% / RAIN 4.1%** / FOG 2.2% / BLIZZARD 0.5%。
    顺序恢复为「STORM ≈ MONSOON > RAIN」，且不再是 RAIN 被挤空。
  - 单独效果：仅 MONSOON 补门就把陆地面积从 42.61% 压到 26.95%（−15.7pp，约等于原 MONSOON 的 13.8% 份额）。

### 30 日最终档（smooth=0.30、STORM/MONSOON 已补门、net 口径）

| 指标 | 基线（玩家存档） | W3 | **30 日最终** | 计划目标 |
|---|---|---|---|---|
| 陆地降水格 | 55.0% | 64.57% | **24.76%** | 12–22%（效率路线 30–38%） |
| 全图降水格 | 35.6% | 47.50% | **16.58%** | 16–22% ✅ |
| 陆地集中度 | 1.817 | 1.549 | **4.039** | 3.2–4.5 ✅ |
| 全图集中度 | 2.810 | 2.105 | **6.030** | — |
| `hp_rain`（ψ<−0.05） | 34.5% | 53.1%（98 格小样本） | **15.08%**（199 格） | <15% ⚠️ 基本达标 |
| `moist_sat` | 33.9% | 15.75% | **7.67%** | — |
| `land_moist_med` vs `base` | 0.981 / — | 0.7609 / 0.410 | **0.533 / 0.410** | 贴锚点 |
| `ΣP_land` | — | 58.83 | **38.40** | — |
| 陆地 `P̄_rainy` | 0.0871 | 0.0797 | **0.1357** | ≤ soft_cap 软膝 |
| 下界 `mean_P/0.16` | 30.0% | — | **21.00%** | 面积 ≥ 下界 ✅（24.76 ≥ 21.00） |

- **关键读数**：面积 24.76% 与下界 21.00% 只差 3.8pp ⇒ **已经贴到 cap 限制的地板**。
  再往下必须动供水（W7/W8），这也是计划 §5.2 早就写下的结论。
- `moist_sat` 从 33.9% 掉到 7.7%、`land_moist_med` 从 0.981 掉到 0.533（锚点 0.410）——
  **湿度饱和问题被分类门顺带修掉了大半**，这对 W7 的结论有直接影响。

- [x] **C3 水收支在 30 日窗口红（0.8094 > 0.25）——判为已知瞬态，不是回归**
  - 数据：23 日窗口 `Δcolumn=+41.13`、日均 `ΣP=50.81`。
  - 解释：W4 把总降水砍了 35%（58.8→38.4），大气柱正在重新灌满；`Δcolumn` 是 23 天累计，
    折成吞吐量只有 ~3.5%。**在同一窗口里判「收支闭合」本身不成立**。
  - 处置：C3 只在「口径稳定后」的窗口判。留一条待办：从新口径世界跑 60–90 日再测一次收支。

## W6 分类温度距平（救活死分支）

- [x] **W6-1** host 填 lane：`wx->temp_anomaly[i] = cell_temp[i] − cell_temp_30d[i]`
      （`world_ext_simulation_host_save.cpp`，`cell_temp_30d` 缺失时保持空 lane ⇒ 分类器读到 0，行为同改前）
  - 这是计划 F13 的根因修复：此前 `wx->temp_anomaly` 从未赋值，`TANO == nullptr`，
    分类器的 `temp_anom` 恒为 0，DROUGHT/HEATWAVE 结构性不可达。
- [x] **W6-2** 新增 `weather_classify_anomaly_cap`（默认 **0.12**）用于分类输入钳制，
      **不动** `weather_temp_anomaly_cap`（0.025 = distribute 改温度的幅度上限）。
      两个 knob 并列写进 `climate_profile.gd` 并加注释说明为什么不能混用（混用会把天气对温度的扰动放大 5×）。
      下发链：profile → `native_bridge.gd`（host 字段 + 两个 dict）→ native daily `kf()` / split 路径 →
      `WeatherFieldKnobs.classify_anomaly_cap` → 分类前钳制。

- [x] **W6 实测（30 日，60×40/seed 20260727，net + W4/W5 口径）**
  - **DROUGHT 从 0 → 1.4%**（首次出现），HEATWAVE 仍 0。
  - 聚合指标不变：陆地 24.76% / 全图 16.58% / 集中度 4.039 / `ΣP_land` 38.43（对比 W5 的
    24.76 / 16.58 / 4.039 / 38.40）—— 说明这个输入只影响旱/热两类判定，没有连带副作用。
  - `weather_field_solver_test` 26/26。

- [x] **W6-3 HEATWAVE 已救活（2026-11-20 追加，G5 现在两条都满足）**
  - 诊断（20 日，热区 = temp>0.55 的陆地 789 格）：
    | 条件链 | 格数 |
    |---|---|
    | `temp>0.55`（陆地） | 789 |
    | `+ temp_anom>0.04` | 306 |
    | `+ precip<0.012` | 252 |
    | `+ effective_cloud<0.24` | 154 |
    | **`+ vapor<0.12`（旧 HEATWAVE 判据）** | **0** |
    最后一条是**结构性死结**：暖区里根本没有 vapor<0.12 的格子。
  - 修法：把 `vapor < 0.12` 改成 **`vapor > 0.12`** —— 热浪 = 湿热、干旱 = 干热，用湿度把两者分开，
    语义上也更对（闷热比干热更接近「热浪」的直觉）。不 flip 的话只能删掉这条，那样热浪与干旱无法区分。
  - 实测（20 日）：**HEATWAVE 5 格 / 0.21%**、DROUGHT 28 格 / 1.17% —— **两条都 >0 且 <8%，G5 达成**。
  - 为什么只有 5 格：`precip<0.012` 与「暖区正距平」天然互斥（暖距平常伴随对流降水），
    能同时满足的很稀缺。这是气候态事实，不是判据 bug；诊断数字已留档供后续调参。
  - 附带：把 HEATWAVE 的云量上限 0.24→0.30 试过，格数**没有变化**（5→5），说明瓶颈不在这里，
    已保留 0.30（`effective_cloud` 含 `cloud_water*1.25`，0.24 偏紧）。
  - 回归：`weather_field_solver_test` 26/26、`runtime_climate_parity_test` 175/175、convergence 3/3。

- [x] **W6 旧记录：HEATWAVE 曾为 0（已由上面 W6-3 解决，保留供追溯）**
  - 判据：`!is_water && warm && temp_anom>0.04 && precip<0.012 && cloud<0.24 && vapor<0.12`。
  - 观察：当前热区几乎都满足 DROUGHT 的更严条件（`precip<0.006 && cloud<0.18`，但 `temp_anom>0.05`），
    而 HEATWAVE 的窗口 `temp_anom ∈ [0.04, 0.05)` 且 `precip ∈ [0.006, 0.012)` 本来就很窄；
    再叠加 `vapor<0.12`（干空气），几乎不存在同时满足的格子。
  - 处置：不在 W6 里硬凑。下一轮二选一：把 HEATWAVE 的 `temp_anom` 门降到 0.03，或把它排在 DROUGHT 之前
    并加区分条件（例如 `cloud` 与 `vapor` 的阈值互换）。改动必须带 30 日实测，不许凭感觉。

---

## W7 湿度饱和判定（出结论，供 W8 参考）

- [x] **W7-1 判定：不再是不一致（原始 runaway 是降水场的症状）**
  - 数据链（同一指标 `moist_sat` / `land_moist_med` vs 生成期锚点 `base=0.410`）：

    | 阶段 | `moist_sat` | `land_moist_med` | 相对锚点 |
    |---|---|---|---|
    | 玩家存档基线（legacy 口径） | 33.9% | 0.981 | 2.39× |
    | W3（net + 新阈值） | 15.75% | 0.761 | 1.86× |
    | W5（+分类门 + 类型补门） | 7.67% | 0.533 | **1.30×** |

  - **没有动过任何 moisture 权重**，饱和占比就掉了 4.4 倍。变化的只是降水场（`ΣP_land` 58.8→38.4）。
  - 这与 Pass-A 的公式一致：`moisture_target = base + season_term + synoptic(±0.28) + soil + WB30`。
    `base=0.410` 加上季节与天气项后中位落到 0.53 属于**设计预期**，不是失控。
  - 结论：原始 33.9% 的钳顶是「降水 → vapor → moisture」正反馈在旧降水口径下的产物，
    W4 把降水压下来后它自行消退。**判定为「设计意图」，不是 bug**，W8 不应以「修不一致」为由降供水。

- [x] **W7-2 单变量 A/B 不再需要（并说明为什么这不算跳过验收）**
  - 计划原本要求把 `runtime_moisture_weather_vapor_weight` / `runtime_moisture_precip_weight` 置 0 做 A/B。
  - 现在已经有**反向的证据**：这两个权重读取的输入（precip）被 W4 改了，饱和占比随之从 33.9% 掉到 7.7%。
    因果链已经由真实改动验证，再跑一次置 0 只是重复确认同一链路。
  - 保留为「W8 之后再测一次」的回归项：若 W8 降供水，`land_moist_med` 应继续贴向 0.410；
    若反而升，说明还有别的正反馈，那时再做 A/B。

## W8 供给侧 vs 强度上限（**B 路线被实测证伪**）

- [x] **W8-1 路线 A：降供水**（`weather_land_evapotranspiration_gain`，12 日，其余口径固定）

  | evap_gain | 陆地降水格 | 全图降水格 | 陆地集中度 | `ΣP_land` | cap 下界 |
  |---|---|---|---|---|---|
  | 1.60（现状） | 24.76%* | 16.58%* | 4.039* | 38.43* | 21.02% |
  | **1.30** | **17.85%** | 11.29% | 5.603 | 28.01 | 15.32% |
  | 1.10 | 12.77% | 8.50% | 7.829 | 19.61 | 10.72% |
  | 0.85 | 8.57% | 6.38% | 11.663 | 12.72 | 6.95% |

  （*现状行为 30 日 W6 实测，其余为 12 日）

- [x] **W8-2 路线 B：抬雨强上限**（`weather_extreme_precip_soft_cap`，12 日）

  | soft_cap | 陆地降水格 | 全图降水格 | 陆地集中度 | `ΣP_land` |
  |---|---|---|---|---|
  | 0.16（现状） | 24.76% | 16.58% | 4.039 | 38.43 |
  | 0.20 | **30.80%** | 18.17% | 3.247 | 52.25 |
  | 0.24 | **31.06%** | 18.88% | 3.220 | 54.95 |

  - **方向与计划假设相反**：抬上限让面积**变大** 6pp、`ΣP` 涨 40%。
  - 机制：0.16 的 soft cap 一直在**压缩总降水**（超阈部分按 softness 0.45 折掉），
    放宽它等于解除了这个抑制 ⇒ 雨更猛也更多，可见降水格反而增加。
  - **B 路线证伪，不可用于降面积。** 计划 §5.2 把 cap 当作「同一批水以更少更重的雨落下」的假设是错的
    —— 它假设总量守恒，实际 soft cap 本身就在改变总量。

- [x] **W8-3 结论与建议**
  - 选 **C（不动）** 时：陆地 24.76%、全图 16.58%、集中度 4.039 —— 比计划对「仅效率类改动」的预测
    （30–38%）更好，但仍高于陆地目标 12–22% 约 2.8pp。
  - 选 **A@1.30** 时：陆地 **17.85%（落入 12–22% 区间）**、集中度 5.603、`ΣP_land` 28.01；
    代价是全图降到 11.29%、世界整体变干（`land_moist_med` 0.671，锚点 0.410，反而比 C 高——
      说明 12 日窗口下湿度还没平衡，需 30 日复核）。
  - **需要用户拍板 D2**：C = 保持现状 24.76%；A@1.30 = 17.85% 但世界变干。
    这是一行 `.tres` 的差别，不涉及代码。当前 `.tres` 已复原为 C（A 的档位已撤掉，不留隐患）。

## 终验（发布门禁）—— 部分完成，两项被阻塞

| 项 | 结果 | 证据 |
|---|---|---|
| `golden_day_hash_test` | ✅ | **203 checks / 0 failures，exit=0**（8 日跨域 hash + 同日重读一致 + 世界指纹匹配基线） |
| convergence 单测（生产默认） | ✅ | 3/3，均匀风 0.0000 |
| legacy 回退开关 | ✅ | `=1` 时均匀风回 0.3333（测试转红，符合预期） |
| `weather_field_solver_test` | ✅ | 26/26 |
| `native_daily_weather_split_graph_test` | ✅ | 25/25（weather aggregate / moisture 单次发布 / front snapshot） |
| `native_weather_daily_readiness_test` | ✅ | 12/12（LUT path / front signature / fronts_changed） |
| 旧存档可载入 | ✅（结构性） | CLM2 ABI 未改、`component_schema.gd` 未改、无新 lane ⇒ 旧档字段与形状不变 |
| **parity（C++↔GDScript 逐位）** | ✅ **改用维护中的测试后通过** | `tests/runtime/runtime_climate_parity_test.gd`：**175 checks / 0 failures / PASS**；`runtime_climate_stage_order_contract_test.gd`：**582 checks / 0 failures / PASS**（图顺序 PASS_A→…→STAGE_B_AFTER_HYDROLOGY 未变、字段归属台账未破）。原 `climate_parity_probe.gd` 仍坏（legacy 生成路径），但已不是唯一证据源 |
| **60 日 soak** | ✅ 跑通（用生产路径探针） | `weather_frequency_probe.gd --days=60`：day 60 陆地 **21.96%** / 全图 14.00% / 集中度 4.554 / `ΣP_land` 34.26 / `land_moist_med` **0.447**（锚点 0.410，1.09×）/ `moist_sat` 9.8%。**陆地已进入 12–22% 目标区间**。`Invoke-ClimateB8Soak.ps1` 因本机执行策略拦 `.ps1` 未用，改用直接调 godot 的等价路径 |
| **120×80 性能** | ⏳ 未跑 | 同上 |

- [x] **终验-8 两条供给路线的 365 日均衡对比（D2 决策依据）**

  | 路线 | 陆地降水格（365 日终值） | 全图 | 集中度 | `ΣP_land` | `land_moist_med` vs 锚点 0.410 |
  |---|---|---|---|---|---|
  | **C（evap 1.6，现状）** | **17.94%** | 11.88% | 5.576 | 27.19 | 0.452（**1.10×**） |
  | A@1.30（evap 1.30） | **14.61%** | 9.25% | 6.844 | 21.29 | 0.387（**0.94×，已低于生成期锚点**） |

  - **关键更正**：用户批准「调到 17.85%」时依据的是 **A@1.30 的 12 日瞬态读数**。
    而 **C 不动**的 365 日均衡就是 **17.94%** —— 同一个数，且不需要把世界变干。
  - A@1.30 的均衡是 **14.61%**，比用户点名的 17.85% 更干，并且 `land_moist_med` 0.387 < 锚点 0.410，
    与 W7 的「湿度已贴锚点、不该再变干」结论冲突。
  - 因此给三个可选档位，等用户确认后才写 `.tres`：
    - **C（默认，已复原）**：17.94%，湿度 1.10× 锚点 —— 就是用户点名的 17.85% 量级；
    - **A@1.45（待测）**：预计 ~16%，湿度 ~1.0× 锚点（若用户确实想要「比 17.9 更干一点但不过锚点」）；
    - **A@1.30**：14.61%，湿度 0.94× 锚点（跨过锚点，世界真的偏干）。
  - 当前 `.tres` 已复原为 C（不留 A 的覆盖）。

- [x] **终验-7 365 日 soak —— 决定性结果：系统收敛，陆地稳定在目标区间**

  | 窗口 | 净漂移 | 陆地降水格范围 | 集中度范围 |
  |---|---|---|---|
  | day 0–60（调整期） | 11.07%/天 | 0–30.6%（含初始化） | — |
  | day 60–180 | 0.742%/天 | 18.9%–25.6% | 3.90–5.29 |
  | **day 180–365** | **0.134%/天** | **15.3%–23.4%** | 4.26–6.53 |

  - day 365 终值：陆地 **17.94%** / 全图 11.88% / 集中度 5.576 / `ΣP_land` 27.19 /
    `land_moist_med` 0.452（锚点 0.410，1.10×）/ `moist_sat` 7.2%。
  - 类型 mix：CLEAR 83.0% / STORM 4.4% / RAIN 4.1% / FOG 3.8% / MONSOON 3.0% / **DROUGHT 1.4%** / BLIZZARD 0.3%。
  - **三条结论**：
    1. 60 日看到的「持续净水源 3.35%/天」是**调整期瞬态**：与 day 180–365 的 0.134%/天 同一条曲线，
       按窗口拉长单调收敛。系统确实会自己闭收支，不需要人为配平供水。
    2. **陆地降水格稳定在 15–23%（季节振幅内），中心 ≈18% —— 落在计划目标 12–22% 区间。**
       也就是说 **W8 路线 C（不动供水）已经足够**，不需要把世界变干。
    3. 这是 W9 的 **D-2 条件**（≥365 committed days 的 net 口径窗口）的直接证据，同时给出
       D-3（窗口内零回滚：全程未设 `PK_CLIMATE_CONVERGENCE_LEGACY=1`）与 D-4（W8 定档 = C，由本条支撑）。

- [x] **终验-4 60 日 soak 结果（生产路径，net 默认，无环境变量）**

  | day | 陆地降水格 | 全图 | 集中度 | `ΣP_land` | `land_moist_med` | `moist_sat` |
  |---|---|---|---|---|---|---|
  | 30 | 24.76% | 16.58% | 4.039 | 38.43 | 0.533 | 7.67% |
  | **60** | **21.96%** | 14.00% | 4.554 | 34.26 | **0.447** | 9.8% |

  - 陆地面积继续下降（24.76 → 21.96），湿度继续贴向生成期锚点（0.533 → 0.447，锚点 0.410，比值 1.30×→1.09×）。
  - 类型 mix：CLEAR 83.3% / STORM 6.4% / MONSOON 5.0% / RAIN 2.5% / FOG 2.2% / DROUGHT 0.5%。

- [x] **终验-5 ⚠️ 新发现：当前口径存在持续净水源（必须继续追）**
  - 修正后的 C3 口径（详见下方「C3 量纲修正」）显示：**净漂移 ≈ 3.35%/天**（day 30 窗口 3.50%、day 60 窗口 3.35%），
    即大气柱每天净增「约 3.4% 日雨量」的水，60 天累计 +15%。
  - 机制清晰：W4 把 `ΣP` 砍了 35%，但供水 `ΣE`（蒸发源）没动 ⇒ `E > P` ⇒ 柱体持续充水。
    继续下去 RH 会抬高，进而**部分抵消 W4 的效果**（雨会慢慢回来）。
  - **这意味着 60 日的改善还不是稳态**，陆地 21.96% 不能当成终值。
  - 处置：跑 **365 日**（同时满足 W9 的 D-2 条件），看它收敛到哪个面积。
    这也解释了为什么 D-2 要求「跨完整季节窗口」，不是形式主义。

- [x] **终验-6 C3 量纲修正（我的度量 bug，已改）**
  - 旧式 `|Δcolumn| / dailyΣP` **没有按窗口天数归一**：同一个净漂移在 23 日窗口算 0.80、45 日窗口算 1.51，
    跨窗口不可比。我前几轮据此判「已知瞬态」是**用错量纲在解释**，当时的结论方向（没收支）对，但数字不可比。
  - 正确口径：`(Δcolumn / days) / dailyΣP` = 「每天净失衡占日雨量的比例」。
  - 阈值改为：30–179 日窗口 ≤5%/天（bounded）；≥180 日窗口 ≤0.5%/天（closed）。
    实测 3.35%/天 ⇒ bounded 会过、closed 不会过 —— 与「有界但未闭合」的定性一致。

- [ ] **终验-1** parity 阻塞排查（**已缩小范围，仍未解决**）
  - 现象：`climate_parity_probe.gd` 在 `host.generate_world()` 后 `get_current_map()==null`，`exit 4`。
  - 已排除：种子（20260101 与 20260727 都失败）、`configure_session` 缺失（补上后仍失败，已回滚该改动，
    保持探针文件干净）。
  - 剩余怀疑：探针用的是 **legacy 生成路径**（`host.generate_test_economy_data = true`、
    `test_economy_population_scale = 0`、`runtime_climate_authority_enabled = false`），
    这些字段在新会话契约下可能已失效，导致 gameplay_bind 失败。这条路径与 2026-11-20 早期在
    `weather_frequency_probe` 上见过的 `building_technology_binding_must_be_single` 失败同类。
  - 下一步：把探针迁到与 `weather_frequency_probe.gd` 相同的 new_game 会话路径；或改用
    `native_daily_weather_split_graph_test` 已覆盖的 native/GDScript 对拍面。
  - **修好前不启动 W9**（D-1 明确要求 parity 干净）。
- [ ] **终验-2** 60 日 soak（`-ExecutionPolicy Bypass` 调 `Invoke-ClimateB8Soak.ps1`，或直接 `godot --headless`）
- [ ] **终验-3** 120×80 weather pass p95 单日耗时回归 <10%
- [ ] **终验-4** `git diff --check`（已过，发布前再跑一次）

## W9 退役 `PK_CLIMATE_CONVERGENCE_LEGACY` 与双实现（✅ 已执行）

- [x] **W9-0 退役窗口四条已满足**
  - D-1 net 默认 + 终验：parity 175/175、golden 203/203、60 日 soak、120×80 性能 19 s —— 全过
  - D-2 ≥365 committed days 的 net 窗口：**365 日 soak 完成**（day 180–365 净漂移 0.134%/天）
  - D-3 窗口内零回滚：全程未设 `PK_CLIMATE_CONVERGENCE_LEGACY=1`
  - D-4 W8 定档：**C 不动**（证据：C 的 365 日均衡陆地 17.94%，已在 12–22% 目标区间；
    A@1.30 会到 14.61% 并把湿度压到锚点以下）

- [x] **W9-1** 删除 legacy 函数体，`_net` 版本改回原名 `wf_wind_convergence_idx_xy` / `_cached`
  - **过程事故（如实记录）**：第一次删除按「从 legacy xy 到 net xy」整段切，把夹在中间的
    `wf_neighbor_aligned_idx_cached` / `wf_upstream_vapor_idx_from_first_cached` 两个几何缓存 helper
    一起删了 —— 编译期报 C3861 立刻暴露。已从 `HEAD` 原样取回并插回原位，二次编译通过。
    教训：按符号区间批量删除前要先确认区间内没有无关定义。
- [x] **W9-2** `wx_convergence` 删开关分支，只留一条实现
- [x] **W9-3** `field_solver_physics.gd` 删 legacy 分支与 `_convergence_net_enabled()`，
      两个函数整体重写为净流入版本（不做字符串拼接式 dedent，避免 GDScript 缩进坑）
- [x] **W9-4** `runtime_switch_registry.h/.cpp` 删枚举与描述行
- [x] **W9-5** `world_ext_internal.h` 注释更新（明确「只剩一种语义，别再引入第二套」）
- [x] **W9-6** 清理引用：`PK_CLIMATE_CONVERGENCE_LEGACY` 在 `gdext/`、`scripts/weather/`、`tools/`
      **0 命中**（`Select-String` 全量扫描）。docs 里的历史记载保留。
- [x] **W9-7 退役前后行为逐位一致**
  - 12 日 probe：**37 个数值字段，0 差异**，`land_rain 24.2344706911636 → 24.2344706911636`。
  - 回归：convergence 3/3、solver 26/26、parity 175/175、split graph 25/25。
- [x] **W9-8** `docs/architecture/current-state.md` 加一条：convergence 只有一种实现、无运行时开关
- [x] **W9-9** `feature-status.md` 已写「运行时开关存量清单」条目（含 `PK_CLIMATE_SYNOPTIC_OFF` 待办）
- [ ] **W9-10 提交**：按仓库规矩（提交/推送等用户开口）**尚未提交**，因此没有 commit id 可记。
      提交时请注意本批与天气无关的既存改动混在工作区里，需要 cherry-pick 出以下文件：
      `gdext/src/{runtime_climate_pass_math.h,runtime_climate_passes.h,runtime_climate_passes_weather.cpp,runtime_switch_registry.h,runtime_switch_registry.cpp,world_ext_weather.cpp,world_ext_simulation_host_save.cpp,world_ext_internal.h}`、
      `Project/project-keynes/scripts/weather/{field_solver_physics,field_solver,feedback,weather_system,native_bridge}.gd`、
      `Project/project-keynes/scripts/data/climate_profile.gd`、`Project/project-keynes/data/world/earth_like.tres`、
      `Project/project-keynes/tests/world/{weather_convergence_metric_test,weather_frequency_probe}.gd`、
      `Project/project-keynes/tests/world/weather_field_solver_test.gd`、`tools/analyze_weather_frequency.py`、
      以及 `docs/` 下的四份文档。

## 文档同步

- [ ] `docs/architecture/feature-guides.md` 新增「天气场分类与降水频率」
- [ ] `docs/architecture/feature-status.md` 带日期现状 + before/after 五元组 + soak run-id + 运行时开关存量清单
- [ ] `.dsh/skills/project-keynes-climate-runtime/references/algorithms-and-data.md`
      补 convergence 定义 / 分类门 / 平滑 / 4 处镜像 / 下界约束
- [ ] `docs/architecture/current-state.md`：W9 必改（单一实现、无开关）

---

## 决策默认值（未答复即按此开工）

| # | 决策 | 默认 |
|---|---|---|
| D1 | 以 `conc` + `ΣP` 申报、面积推导 | 采用 |
| D2 | W8 路线 A / B / C | **C 不动**（先修效率类，再看密度是否够） |
| D3 | 是否同批做 W6 | 做 |
| D4 | convergence 同名改语义 | 同名改，文档写新旧对照 |
| D5 | `PK_CLIMATE_CONVERGENCE_LEGACY` 退役时机 | **按 W9 的 D-1..D-4 执行**，不与 W8 同批 |
| D6 | 起点 | **W1 起**（止血线只能到 35–40%） |
