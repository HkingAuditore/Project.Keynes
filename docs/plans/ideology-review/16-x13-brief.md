# 16 - X13 气候能力（reviewer brief，2026-10-23 22:05）

队列位置：15（X4）之后。X13-a（派生列）不依赖 X4，可以提前；X13-b（灾害事件叠层）依赖 15。
只走 worker 路径。不调数值。

## 1. 现状事实

- Economy 每日气候输入只有 8 条 f32：`RuntimeEconomyDayInput::fields`（`runtime_pod_protocol.h:215`）=
  temp / temp30 / moisture / PAW / precip / snow / weather_intensity / elevation。**没有** 年均温、天气类型、洪涝覆盖。
- 这些量在 climate 侧都已存在（`RuntimeClimateStore`，`runtime_authoritative_domains.h:35+`）：
  - `temperature_365d_ema`（`:42`）；主线程 slot `cell_temp_365d`（`component_bind_table.gen.h:37`）；
  - `weather_type`（u8；`CLEAR=0 RAIN=1 STORM=2 BLIZZARD=3 DROUGHT=4 FOG=5 HEATWAVE=6 MONSOON=7`，
    `runtime_climate_pass_math.h:1036`）；slot `cell_weather_type`；
  - `cover`（u8，洪涝 = `cv_flooding`，`runtime_climate_passes.cpp:4700`）；slot `cell_cover`；
  - `vegetation_drought_streak`（int32，植被干旱连日）。
- 喂给 Economy worker 的两条路径都要改：
  - climate worker 权威：`native_simulation_host.cpp:12537-12547` 从 `climate_store` 拷 lane；
  - 否则：`world_ext_simulation_host.cpp:2118-2131` 从主线程 slot 拷。
- 降雨日已有：`capture_environment` 里算 `_cell_rain_event_q16`（`economy_runtime.cpp:4500`），metric 13。
- 当前 metric 上限 70（`PK_EFFECT_INPUT_METRIC_REVISION_CAPACITY`，`economy_runtime.h:110`）；Economy schema 56。

## 2. 设计决定

### D1. 输入扩宽（一次做完）

- `fields` 8→10：追加 `temp_365d`（f32）。`geography` 不动；新增 `std::array<std::vector<uint8_t>, 2> climate_u8`
  = weather_type / cover。两条喂入路径同时改；缺 lane 时 `capture_environment` 报
  `economy_environment_snapshot_invalid`（fail-closed，不要静默当 0）。
- `capture_environment` 里量化并存为 Economy 列（与现有 `_environment_*_q16` 同形），进入环境 hash。

### D2. 派生列与 metric（X13-a）

全部在 `capture_environment` 的同一个逐格循环里更新，O(cells)，不新增遍历。

| metric | key | 定义 | 存档 |
|---|---|---|---|
| 70 | `cell.temperature_annual_q16` | `temp_365d` 量化 | 派生（每日重算） |
| 71 | `cell.dry_streak_days` | 无降雨连日：`rain_event ? 0 : +1`，饱和 3650 | **持久**（int16/int32 列） |
| 72 | `cell.hazard_today_mask` | bit0 洪涝（cover==flooding），bit1 干旱（weather==DROUGHT），bit2 霊冻（weather==BLIZZARD 或 temp < 冰点知识 `snow_freeze_t` 且 temp30 ≥ 冰点），bit3 热浪（weather==HEATWAVE） | 派生 |
| 73 | `cell.days_since_hazard` | 任一 hazard bit → 0，否则 +1，饱和 3650 | **持久** |
| 74 | `cell.temperature_anomaly_q16` | `temp - temp30`（有符号 Q16） | 派生 |

- `FAMILY_METRIC_COUNT` 70→75，`PK_EFFECT_INPUT_METRIC_REVISION_CAPACITY` 同步，`stat_key_families.gd` / 生成器
  metric 表同步。Economy schema 56→57（两条持久列）。若 15 的 X4-b 同期做，合并为一次 bump。
- 新 tag（生成器 tag 表，走现有 tag 机制）：`cell.climate.cold`（70 ≤ 5℃）、`cell.climate.hot`（70 ≥ 22℃）、
  `cell.climate.dry_spell`（71 ≥ 20）。℃→Q16 的换算用 climate 温度归一化的同一公式，写成生成器常量并注明来源。
- 国家级汇总一个：`country.hazard_free_cell_share_q16`（自有格中 73 ≥ 365 的份额，`mandate_of_heaven` 用），
  在提交尾的国家 tag 计数同一遍里算（不新增全网格扫描）。
- P1-A digest：新 metric 列进 `refresh_effect_input_digest` 的按消费者掩码摘要；只在有卡声明时计入。
  注意 71/73 每天必变，声明它们的卡必须用阈值条件（exact-threshold digest，已有），不得按原值触发。
  生成器加硬校验：引用 71/73/74 的 program 必须经阈值或 tag，禁止直接 `Ramp`。

### D3. 灾害事件（X13-b，依赖 15）

- 在 15 D3 的 `CommitEvent` 里加 kind：`FLOOD_START` / `DROUGHT_START` / `DROUGHT_END` / `FROST` / `HEATWAVE` /
  `RAIN_AFTER_DRY{value=之前的 dry_streak}`。都由 72 / 71 的「昨天 vs 今天」边沿产生，只需保留上一日
  hazard mask（持久 u8 列，计入 schema 57）。
- 不是叠层的「灾后 N 天」效果（河伯祭、霊信、赈旱）用 X4 层环 `max_stacks=1`：再次事件 = 替换最早层 =
  刷新时间，正好等于设计表「不叠加，再次洪水刷新时间」。不要另做「计时器」机制。
- 灾害损失修正（「损失 -30%」）已有通道：国家级 `_epoch_country_climate_loss_factor_q16`（`economy_runtime_building_production.cpp:132`）。
  格级「灾后 30 天损失 -30%」需要一条格级 loss stat（`economy.city.climate_loss_factor`）并在同一处乘入；
  这是另一个小项，放 X13-b。

### D4. 明确排除（本期不做，写进 `KNOWN_CAPABILITIES` 的排除表）

- 「雨季 = 本国多年平均降水最多的 3 个月」（`monsoon_trade`）：需要每国 12 个月的长期降水统计。改写为
  「当前天气 MONSOON 或 precip ≥ 阈值」的 v1 版本由 C 决定；如果内容必须按月统计，就列为排除。
- `climate_engineering`（自动选「去年损失最大的灾害」）、`cloud_seeding`（人造降雨触发其他卡的降雨事件）：
  属于 X5/元机制，不在 X13。

## 3. 不要做的事

- 不要在 Ideology 侧自己存旱期/灾害计数；累计器只在 Economy（输入域）。
- 不要复用 `vegetation_drought_streak` 作为「无降雨天数」：它是植被干旱应力连日，语义不同。
- 不要给主线程单独实现；主线程 slot 路径只是「把 lane 拷进输入」。

## 4. 验收（worker，0xFFF）

`tests/ideology/ideology_worker_x13_test.gd`，用测试入口覆盖气候 lane（覆盖的是输入）：

- **T1** 连续 25 天无降雨 → metric 71 = 25，`cell.climate.dry_spell` tag 在第 20 天亮；降雨一天 → 0、tag 灭。
- **T2** 覆盖 cover = flooding 一天 → 72 bit0 = 1、73 = 0；之后每天 +1。
- **T3** temp_365d 覆盖到 ≤ 5℃ → `cell.climate.cold` 亮；用一个诊断 program（`v8_cold_cell`）验证因子生效与撤销（依赖 14）。
- **T4** 存档→读档：71/73/上一日 mask 逐位相等；旧 schema 56 存档 fail-closed。
- **T5** 缺 lane（故意不喂 weather_type）→ 报 `economy_environment_snapshot_invalid`，不是静默 0。
- **T6**（X13-b，15 之后）洪水事件 → `river_god` 型诊断 program 挂 1 层 60 天；第 30 天再洪水 → 到期推到第 90 天。
- 计数器：`capture_environment` 耗时与改前同量级（只报数，不设门）。

上线：X13-a 开关 `X13a` 加入 `AVAILABLE_CAPABILITIES`；卡由 C 恢复后按 `CARD_REQUIRES` 发布。
