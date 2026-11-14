# 四项 C++ 改动的实施说明书

> 这四项从第 8 轮起每轮都在汇报里请求授权，至今未获批准，因此**代码未动**。
> 本文件把每一项改成"照着做就行"的说明书：改哪个文件、哪一行、为什么、风险、回滚、怎么验证。
> 一旦授权，任何一项都可以在 30 分钟内落地并跑完全部九道门禁。
>
> 记录时间：v5 改造第 29 批（2026-11-11）。

---

## 汇总

| # | 项目 | 文件 | 影响 | 风险 |
|---|---|---|---|---|
| 1 | 3 个天气信号从未发布 | `scripts/`（新增发布器） | 天气类科技路线永远不可达 | 中 |
| 2 | `bast_fiber` 与 `flax_fiber` 共用 contact rule 5 | `gdext/src/economy_runtime_trade.cpp:1758` | 贸易规则语义被覆盖 | 低 |
| 3 | **8 个**军事 stat 从未被读取 | `gdext/src/military_core_war.cpp` | 科技给的攻防加成完全不生效 | **高** |
| 4 | `local_defence()` 没有科技门槛 | `gdext/src/military_core_war.cpp:186` | 无防御科技的文明也有城防 | 中 |

---

## 1. 三个天气信号从未发布

### 现状（已核实）

信号在 GDScript 里**有定义**：

```
scripts/technology/research_signal_catalog.gd:182  weather.freeze_thaw
scripts/technology/research_signal_catalog.gd:183  weather.heatwave
scripts/technology/research_signal_catalog.gd:184  weather.prolonged_wet_season
```

但**全工程没有任何发布调用**：

- `country_facade.gd:339 discover_research_signal(handle, signal_id, cell, …)` 是唯一入口；
- 在整个 `scripts/` 目录下 grep `discover_research_signal(`，只命中它自己的定义（1 处）；
- C++ 侧的落地在 `country_core_apply.cpp:760` 附近（命令 case 13/14），
  把信号位写进 `state.country_research_signals`，但**上游没人投递该命令**。

结论：任何依赖这三个信号的科技路线/揭示条件**永远不可达**。

### 建议改法

1. 在天气推进的地方（`world_runtime_host.gd` 的每日天气阶段，或 `runtime_climate_kernel` 的
   `WeatherType` 分类出口）加一张映射表：

   ```
   WT.HEATWAVE              → &"weather.heatwave"
   WT.BLIZZARD / 冻融判定   → &"weather.freeze_thaw"
   连续湿季（moisture 超阈 N 日）→ &"weather.prolonged_wet_season"
   ```

2. **边沿触发**，不要每天每格发：只在 `cell` 的 `weather_type` 由非该类型转为该类型时投递一次，
   并按 `(signal_id, cell)` 去重（`research_signal_evidence` 已经按信号+格记录 count，可复用）。

3. 调用 `facade.discover_research_signal(handle, signal_id, cell)`；handle 取该格所属国家。

### 风险与回滚

- 风险：逐格逐日调用会造成 O(cells) 的额外开销。**必须边沿触发 + 只处理有国家的格**。
- 回滚：新增调用点都是独立函数，删掉即可；不涉及存档结构（信号位本来就存在）。

### 验证

- 单测：构造一个 heatwave 天气的格，跑 2 天，断言 `has_research_signal` 为真且第 3 天不再重复计数。
- 门禁：`validate_network.gd` + 九道全跑（信号只是运行时输入，不应改变拓扑）。

---

## 2. `bast_fiber` 与 `flax_fiber` 共用 contact rule 5

### 现状（已核实）

```
gdext/src/economy_runtime_trade.cpp:1758
    else if (good_id == "bast_fiber" || good_id == "flax_fiber")
        contact_rule = 5;
```

两条纤维共用同一个 `contact_rule`。如果设计上两者应走不同的接触规则（不同生态带/不同接触方式），
那 `bast_fiber` 的规则会被 `flax_fiber` 覆盖掉 —— 这正是"被覆盖"的来源。

### 建议改法（二选一，推荐 A）

**A. 保持共用，但把语义写清楚（零风险）**
把这一行拆成注释明确的合并分支，并在设计文档里登记"两种纤维走同一接触规则"，
避免以后有人误以为是被覆盖的 bug：

```cpp
// bast_fiber 与 flax_fiber 刻意共用规则 5：两者都是温带/亚热带的韧皮纤维，
// 接触与传播路径相同。若要分开，需要新增规则 6 并同步规则消费表。
else if (good_id == "bast_fiber" || good_id == "flax_fiber")
    contact_rule = 5;
```

**B. 真正分开（低风险但有连带）**
1. 在规则表尾部新增 `6`，并更新所有消费 `contact_rule` 的地方（grep `contact_rule` 全量确认）；
2. 把 `bast_fiber` 指向 6；
3. 跑 `tools/audit_technology_unlock_progression.py` 与九道门禁。

### 回滚

只改一行判断，`git revert` 即可；不涉及存档。

---

## 3. 八个军事 stat 从未被读取（最重要的一项）

### 现状（已核实）

`world_ext_military.cpp:670-673` 把 stat 键注册进 `kMilitaryStatKeys`，
`military_core.h` 里有 `MSTAT_*` 枚举，桥接层会读真实 Modifier 值。
但**全工程 grep 下来，下列 8 个 `MSTAT_*` 除了枚举定义与键表之外没有任何读取点**：

```
MSTAT_ATTACK            攻击加成
MSTAT_DEFENSE           防御加成
MSTAT_SUPPLY_TRANSPORT  补给运输
MSTAT_BARRACKS_CAPACITY 兵营容量
MSTAT_DESERTION         逃兵率
MSTAT_FORTIFICATION     城防
MSTAT_MILITIA           民兵系数
MSTAT_CONVOY_ESCORT     护航
```

`military_core_war.cpp` 实际只读了：`CASUALTY`、`FRONTAGE`、六个 `RULE_*`。
（`VISION_ADD` 与 `OCCUPATION_TAX` 在别处有读取，不在缺失名单里。）

**后果**：科技面板上写着"攻击 +X%"，战斗结算里根本不看这个数 —— 玩家研究完毫无效果。

### 建议改法（分三步，每步独立可验证）

**第一步：攻防（收益最大、改动最小）**

- `military_core_war.cpp` 的战斗伤害计算处（`MSTAT_CASUALTY` / `MSTAT_FRONTAGE` 附近），
  把双方战力各乘一次：

  ```
  我方有效攻击 = attack * (attack_factor_q16 / Q16)
  我方有效防御 = defense * (defense_factor_q16 / Q16)
  ```

- 只在**一次**结算入口改，避免"攻防被乘两次"（历史上这类重复相乘是本项目踩过的坑）。

**第二步：工事与民兵**

- `local_defence()`（`military_core_war.cpp:186`）里：
  - 乘 `MSTAT_FORTIFICATION`（工事加成）；
  - 民兵部分乘 `MSTAT_MILITIA`；
  - 若该国家**没有**任何防御类科技（见第 4 项），则不加城防基数。

**第三步：后勤与辅助**

- `MSTAT_SUPPLY_TRANSPORT` → 补给半径/运输量；
- `MSTAT_BARRACKS_CAPACITY` → 训练队列上限；
- `MSTAT_DESERTION` → 每日逃兵判定；
- `MSTAT_CONVOY_ESCORT` →  convoy 被拦截时的损失系数。

### 风险与回滚

- **风险高**：改战斗数值会直接影响平衡；且第一步若位置选错会出现"双乘"。
- 建议先只做第一步 + 第二步，跑 `tests/` 里军事相关用例与一局 50 天 headless 记录对比。
- 回滚：每步单独提交，独立 revert。

### 验证

- 修改前后各跑一次 `tools/technology_tree/probe_military_catalog.gd`（结构不变，应都为 ok）。
- 用 `docs` 里的性能/结果记录流程跑同一种子 50 天，比较伤亡与战线推进是否合理变化。

---

## 4. `local_defence()` 没有科技门槛

### 现状（已核实）

```
gdext/src/military_core_war.cpp:186  int64_t local_defence(const MilitaryCore &core,
                                        const MilitaryWorldDigest &digest, int32_t cell)
gdext/src/military_core_war.cpp:658  const int64_t local = local_defence(*this, digest, far_cell);
```

函数直接累加该格及邻格的驻军防御，**不检查该国家是否解锁过任何防御/筑城科技**。
结果：一个连"土垒"都没研究过的文明，城防强度与研究了全套筑城的文明一样。

### 建议改法

1. 在 `local_defence()` 内读 `MSTAT_FORTIFICATION` 与 `MSTAT_MILITIA`：
   若两者都为默认值（即没有任何相关科技），则城防只按驻军本身的 `defense` 计，
   不加任何"城墙"基数；
2. 城防基数乘 `fortification_factor`；
3. 若该格有 `military.rule.hold_the_line`，再叠加该条令（已有实现，复用它）。

### 风险与回滚

- 风险中：会让早期文明更脆弱，需要同步检查 `militia` 兵种是否仍能守住起始城。
- 回滚：只改 `local_defence()` 一个函数体。

---

## 建议的实施顺序

1. **第 2 项**（一行注释/一个规则号）—— 最低风险，先把"覆盖"这件事定性；
2. **第 4 项**（`local_defence` 加门槛）—— 中等风险，但它是第 3 项第二步的前提；
3. **第 3 项第一步**（攻防乘算）—— 收益最大，改一处结算入口；
4. **第 1 项**（天气信号发布器）—— 独立子系统，不影响战斗平衡；
5. **第 3 项第三、四步**（后勤与辅助 stat）—— 最后做，逐步验证。

每完成一项：跑九道门禁 + `git commit` 单独提交，便于回滚。

---

## 附：本文件所有结论的取证命令

```powershell
# 1. 天气信号定义与"无调用点"
Select-String -Path scripts/technology/research_signal_catalog.gd -Pattern "weather\."
Get-ChildItem scripts -Recurse -Filter *.gd | Select-String -Pattern "discover_research_signal\("

# 2. bast_fiber 覆盖点
Select-String -Path gdext/src/economy_runtime_trade.cpp -Pattern "bast_fiber" -Context 4,4

# 3. 军事 stat 未读取
Select-String -Path gdext/src/military_core_war.cpp -Pattern "MSTAT_[A-Z_]+" -AllMatches
Select-String -Path gdext/src/world_ext_military.cpp -Pattern "country.military." -Context 0,30

# 4. local_defence
Select-String -Path gdext/src/military_core_war.cpp -Pattern "local_defence"
```

---

## 实施状态（2026-11-11 更新，已获授权）

| # | 项目 | 状态 | 说明 |
|---|---|---|---|
| 2 | `bast_fiber` 被覆盖 | ✅ **已修** | `economy_runtime_trade.cpp` 的首个分支改成只匹配 `flax_fiber`，`bast_fiber` 因此落到规则 10 |
| 3 | 军事 stat 未读取 | ✅ **第一步已做** | `MSTAT_ATTACK` / `MSTAT_DEFENSE` 已进入战斗结算（攻方一次、守方每支军队一次） |
| 4 | `local_defence()` 无科技影响 | ✅ **已做** | 城防现在乘 `MSTAT_MILITIA` 与 `MSTAT_FORTIFICATION`；无相关科技时这两个值为 1.0，行为与改造前一致 |
| 1 | 三个天气信号 | ❌ **未做** | 卡在"没有 cell→country 的 GDScript 访问器"（详见下） |
| — | `steam_powder_works` 主科技 | ✅ **已改** | 从 `tech.steam_power` 改为 `tech.military.powder_milling`；`black_powder` 物资同步去掉 `steam_power` 标签；为此加的 `steam_power ⇠ gunpowder_formulation` 边已撤 |

编译验证：`scons platform=windows target=template_debug dev_build=no -j8` 通过，
产物 `addons/dots_ext/bin/windows/dots_ext_maint_v1.windows.template_debug.x86_64.dll`
（即 `dots_ext.gdextension` 里 debug 指向的那个文件）。
**template_release 尚未重建**，发行包需要再跑一次 `target=template_release`。

### 第 1 项为什么没做

信号 API 本身是通的：

```
country_facade.gd:339  discover_research_signal(handle, signal_id, cell, source_kind, effective_day, sequence)
```

但要做"天气 → 信号"的发布器，需要在每日推进里拿到 **cell → country handle** 的映射，
而 GDScript 侧只有 `MapData.country_slot_arr`（slot，不是 handle），
handle 数组出现在 `facade.snapshot()["country_handles"]`，但没有按 cell 查询的公开接口。
再加上 `_clock_day_changed_impl` 是逐日热路径（有 `day_cost_ema` 预算），
贸然加全地图扫描会直接拉低吞吐。

两条可行路线（都需要先补一个访问器）：

1. **C++ 侧加 getter**：在 `country_api.cpp` 暴露 `get_cell_owner_handle(cell)`（数据已在 territory CSR 里）；
   GDScript 发布器按每日 256 格的预算轮转扫描，边沿触发去重。
2. **改在气候回灌处**：`_apply_climate_writeback_if_authoritative` 已经逐日遍历 MapData，
   在那里顺带检查天气类型并投递信号，天然不需要额外扫描。

在访问器就位前，`weather.heatwave` / `weather.freeze_thaw` / `weather.prolonged_wet_season`
三个信号仍然**不会有任何事件投递**，依赖它们的科技路线依然不可达。
