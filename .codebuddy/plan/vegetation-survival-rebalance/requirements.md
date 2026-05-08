# 植被生存力重平衡需求文档（A+B+C 全套）

## 引言

当前 `map_generator.gd::_apply_vegetation_dynamics` 中的植被生命值（`vegetation_vitality`）动力学存在严重的"一碰就死"问题，与现实生态学规律明显不符。主要病灶有四处：

1. **对称漂移公式**：`dv = (compat - 0.5) * 2 * rate` —— 只要气候适配度 `compat` 低于 0.5 就每天净扣血，忽略了"勉强适应就能维持"的现实缓冲。
2. **容忍度过严**：雨林/极旱沙漠等的高斯带宽仅 0.10–0.12，temperature 稍偏 1 个 tolerance 就会让 compat 跌破 0.4。
3. **天气惩罚一刀切**：DROUGHT 每天 −0.030、BLIZZARD 每天 −0.012，且**不区分植被自身抗性**（沙漠灌木被旱灾打得和雨林一样狠，显然离谱）；30 天即可从 vitality=1.0 掉到 0.1。
4. **演替触发过快**：`VITALITY_LOW_THRESHOLD=0.30`、`SUCCESSION_DEGRADE_DAYS=30` 意味着一次季节性气候波动就能让森林→灌丛→草原→沙漠连降数级，且演替后 vitality 只被重置为 0.5，非常靠近阈值，极易触发连锁退化。

本需求整合三条思路进行系统性重平衡：

- **方案 A（数值微调）**：调低基础变化率与天气惩罚，抬高演替阈值耐受时间；保留现有机制框架，零风险。
- **方案 B（非对称漂移 + 死区）**：引入 `compat ∈ [0.4, 0.6]` 的中性死区（不扣血也不回血），且退化速率带 `harshness` 系数，体现"适应强于逆境"的现实规律。
- **方案 C（植被抗性差异化）**：为每种 `VegetationType.VEG` 附加 `WEATHER_RESISTANCE` 查询表，让沙漠灌木抗旱、雨林抗热浪、泰加抗暴风雪，天气惩罚按 `(1 - resistance)` 缩放。

此外，必须修复"演替后 vitality=0.5 极易再次跌破阈值"导致的多米诺连锁死亡问题。

本方案**只修改数值/公式层逻辑**，不新增文件、不改动 MapData/HexCell 结构、不影响存档格式。

---

## 需求

### 需求 1：基础数值常量重平衡（方案 A）

**用户故事：** 作为一名世界模拟系统开发者，我希望将生命值漂移速率、天气惩罚强度、演替触发阈值调整到符合现实生态学时间尺度的量级，以便植被不会因一次短期气候波动就大面积死亡。

#### 验收标准

1. WHEN `_apply_vegetation_dynamics` 每日执行 THEN 系统 SHALL 使用 `VITALITY_CHANGE_RATE = 0.012`（由 0.02 调低，约对应 83 天从 0 到 1），取代原有 0.02。
2. WHEN 计算天气惩罚时 THEN 系统 SHALL 将 `WEATHER_VITALITY_PENALTY` 中各天气类型的基础值整体缩放到原值的 40%（DROUGHT 0.030→0.012、BLIZZARD 0.012→0.005、HEATWAVE 0.018→0.007、STORM 0.005→0.002、MONSOON 0.005→0.002）。
3. WHEN 判断是否进入退化 streak 时 THEN 系统 SHALL 使用 `VITALITY_LOW_THRESHOLD = 0.20`（由 0.30 调低），让只有真正濒死的 cell 才开始计数。
4. WHEN 判断是否进入升级 streak 时 THEN 系统 SHALL 保持 `VITALITY_HIGH_THRESHOLD = 0.85` 不变（原本就较合理）。
5. WHEN 累计退化 streak 达到触发阈值时 THEN 系统 SHALL 使用 `SUCCESSION_DEGRADE_DAYS = 90`（由 30 提升，约 1 个完整季度）。
6. WHEN 累计升级 streak 达到触发阈值时 THEN 系统 SHALL 使用 `SUCCESSION_UPGRADE_DAYS = 120`（由 60 调整，约 4 个月）。
7. IF vitality 长期处于 `[LOW, HIGH]` 中性区间 THEN 系统 SHALL 按原有 `streak -= 1` 的逻辑缓慢清零，避免遗留计数。

---

### 需求 2：非对称漂移公式与死区（方案 B）

**用户故事：** 作为一名关心生态真实感的玩家，我希望植被在气候"勉强过得去"时能保持稳定而不是每天扣血，这样森林能扛过一次旱季，草原也不会因一次异常降温就倒退成沙漠。

#### 验收标准

1. WHEN 当天 `compat ≥ 0.6` THEN 系统 SHALL 按正向公式 `dv = (compat - 0.5) * 2.0 * VITALITY_CHANGE_RATE` 增加 vitality（与原公式的正向段一致）。
2. WHEN 当天 `compat ≤ 0.4` THEN 系统 SHALL 按负向公式 `dv = -(0.5 - compat) * 2.0 * VITALITY_CHANGE_RATE * COMPAT_HARSHNESS` 减少 vitality，其中 `COMPAT_HARSHNESS = 1.2`（略高于 1，表示极度不适应确实比适应恢复更快）。
3. WHEN 当天 `compat ∈ (0.4, 0.6)` THEN 系统 SHALL 视为"中性死区"，基础漂移 `dv = 0`（不扣血也不回血，由天气惩罚/天气恩赐单独处理）。
4. IF 当前 cell 的 `vegetation == VegetationType.VEG.NONE` THEN 系统 SHALL 跳过基础 compat 漂移（NONE 的 vitality 不会自然衰减），但仍参与天气惩罚和升级 streak 计数（保持原先"从 NONE 演替到 DESERT_SCRUB"的先驱机制）。
5. WHEN 计算天气惩罚后叠加 THEN 系统 SHALL 最终按 `cell.vegetation_vitality = clampf(vitality + dv - penalty, 0.0, 1.0)` 更新，确保死区内仍会受天气影响。

---

### 需求 3：植被抗性差异化（方案 C）

**用户故事：** 作为一名世界模拟系统开发者，我希望每种植被面对不同天气灾害有自身的抗性系数，这样沙漠灌木不会被旱灾一波带走、雨林不会被热浪秒杀，更贴近现实生态学。

#### 验收标准

1. WHEN [`vegetation_type.gd`](/Godot/ProjectKeynes/Project.Keynes/Project/project-keynes/scripts/vegetation_type.gd) 初始化 THEN 系统 SHALL 暴露一个新的静态字典 `_WEATHER_RESISTANCE: Dictionary`，键为 `VEG` 枚举，值为嵌套字典 `{WeatherType.WT.<灾害>: resistance_0_1}`。
2. WHEN 任意植被未在 `_WEATHER_RESISTANCE` 中显式声明某项抗性 THEN 系统 SHALL 默认返回 0.0（即完全无抗性，按基础惩罚扣血）。
3. WHEN `_apply_vegetation_dynamics` 计算天气惩罚时 THEN 系统 SHALL 将原惩罚乘以 `(1.0 - resistance)`，即 `penalty = base_penalty * wi * (1.0 - resistance)`。
4. WHEN 定义 DROUGHT 抗性表时 THEN 系统 SHALL 至少覆盖以下映射（单位为 [0, 1]）：
   - `XERIC_DESERT: 0.90`、`DESERT_SCRUB: 0.80`、`TEMPERATE_STEPPE: 0.55`、`SAVANNA: 0.50`、`MEDITERRANEAN_SHRUB: 0.55`、`TEMPERATE_GRASSLAND: 0.35`
   - `TROPICAL_RAINFOREST: 0.05`、`SWAMP: 0.10`、`MARSH: 0.10`、`MANGROVE: 0.10`（湿生植被最怕旱）
5. WHEN 定义 BLIZZARD 抗性表时 THEN 系统 SHALL 至少覆盖：
   - `POLAR_DESERT: 0.90`、`TUNDRA: 0.85`、`ALPINE_TUNDRA: 0.85`、`TAIGA: 0.75`、`BOREAL_SHRUB: 0.70`、`ALPINE_MEADOW: 0.50`
   - `TROPICAL_RAINFOREST: 0.0`、`MANGROVE: 0.0`、`SAVANNA: 0.10`（热带植被完全扛不住暴风雪）
6. WHEN 定义 HEATWAVE 抗性表时 THEN 系统 SHALL 至少覆盖：
   - `XERIC_DESERT: 0.85`、`DESERT_SCRUB: 0.75`、`SAVANNA: 0.65`、`TROPICAL_DRY_FOREST: 0.55`、`TROPICAL_RAINFOREST: 0.30`
   - `TUNDRA: 0.0`、`POLAR_DESERT: 0.0`、`TAIGA: 0.10`、`BOREAL_SHRUB: 0.15`（寒带植被最惧热浪）
7. WHEN 定义 STORM / MONSOON 抗性表时 THEN 系统 SHALL 至少覆盖：
   - `TROPICAL_RAINFOREST: 0.60`、`MANGROVE: 0.70`（根系/树冠发达，抗风）
   - `TEMPERATE_GRASSLAND: 0.40`、`DESERT_SCRUB: 0.30`
8. WHEN `vegetation_type.gd` 暴露抗性查询 THEN 系统 SHALL 提供静态方法 `static func weather_resistance(v: VEG, wt: int) -> float`，外部调用返回 [0, 1] 的抗性值（未定义时返回 0.0）。

---

### 需求 4：防止演替后连锁死亡

**用户故事：** 作为一名玩家，我希望植被在退化一次之后有一段"缓冲期"能稳定下来，而不是因为新植被的 vitality 起点过低导致接连几级退化形成多米诺效应。

#### 验收标准

1. WHEN `_trigger_succession` 执行退化演替后 THEN 系统 SHALL 将 `cell.vegetation_vitality` 重置为 `0.65`（由 0.5 提升），远离 `VITALITY_LOW_THRESHOLD=0.20`，给新植被足够适应时间。
2. WHEN `_trigger_succession` 执行升级演替后 THEN 系统 SHALL 保持 `cell.vegetation_vitality = 0.7` 不变。
3. WHEN 任意演替发生后 THEN 系统 SHALL 将 `_vitality_low_streak` 和 `_vitality_high_streak` 同时清零（保持原有行为）。
4. IF 演替后新植被在当前气候下 `compat` 仍低于 0.4 THEN 系统 SHALL 正常继续累计下一轮退化 streak（仍需 `SUCCESSION_DEGRADE_DAYS = 90` 天才会再触发），确保"极端不宜居地区终将沙漠化"的最终结局仍可达成，只是不会瞬间连跳几级。

---

### 需求 5：保持向后兼容与可调试性

**用户故事：** 作为一名维护者，我希望此次重平衡不破坏现有存档、不改动数据结构、不影响其他子系统，且所有数值仍以顶层常量形式暴露便于未来调试。

#### 验收标准

1. WHEN 本次修改完成 THEN 系统 SHALL 不修改 [`hex_cell.gd`](/Godot/ProjectKeynes/Project.Keynes/Project/project-keynes/scripts/hex_cell.gd) 中 `vegetation_vitality`、`_vitality_low_streak`、`_vitality_high_streak` 的定义（字段名与类型保持不变）。
2. WHEN 本次修改完成 THEN 系统 SHALL 不影响 [`weather_type.gd`](/Godot/ProjectKeynes/Project.Keynes/Project/project-keynes/scripts/weather_type.gd) 中已有的 `WeatherType.WT` 枚举。
3. WHEN 本次修改完成 THEN 所有新增/修改的数值 SHALL 以 `const` 形式集中暴露于 `map_generator.gd` 顶部"Pass 3"注释块附近，或暴露于 `vegetation_type.gd` 顶部，方便后续数值调参。
4. WHEN 本次修改完成 THEN 系统 SHALL 不改变 `_apply_vegetation_dynamics` 的对外签名（仍返回 `bool` 表示是否有 cell 的 vegetation 被改写），调用方 `map_generator.gd` 其他 pass 代码无需改动。
5. IF 运行时读取旧存档（`vegetation_vitality` 已存在但当时公式不同） THEN 系统 SHALL 使用当前值继续演算，不做迁移（vitality ∈ [0, 1] 语义未变，自然收敛）。

---

## 成功标准（Definition of Done）

- 在典型"温带森林 + 一次连续 45 天中等旱灾"测试场景下：森林 vitality 不会跌破 0.20，**不会退化**。
- 在"温带森林 + 连续 120 天强旱灾（wi≈0.8）"测试场景下：森林最终**会**退化到草原（符合现实），但不会在 30 天内就退化。
- 在"沙漠灌木 + 连续 60 天中等旱灾"测试场景下：沙漠灌木 vitality 基本稳定在 0.6 以上（DROUGHT 抗性 0.80 使惩罚缩减 80%）。
- 在"雨林 + 连续 60 天热浪（wi≈0.7）"测试场景下：雨林 vitality 缓慢下滑但不死绝，模拟现实中的"雨林耐热但惧长旱"。
- 现有存档加载后可正常继续模拟，无脚本报错。
