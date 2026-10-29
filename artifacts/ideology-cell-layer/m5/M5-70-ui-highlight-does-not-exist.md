# M5-70 「UI 高亮验收」不是没做，而是**要验收的 UI 不存在**

| 项目 | 内容 |
|---|---|
| 触发 | 核查 §18.4「native docs、架构边界、skill、**内容文案与 UI 同步**」里剩下的 UI 项 |
| 结论 | **代码里没有任何 UI 消费派生地块层** |
| 日期 | 2026-10-28，Asia/Hong_Kong |

## 1. 我查了什么

```
1) 所有 scripts/ 下的 .gd 里搜 ideology.*highlight / affected_cell / target_cells.*highlight
   -> 只有天气的 _cyclone_affected_cells，与理念无关

2) 所有 scripts/ 下的 .gd 里搜这三个「能拿到派生层数据」的接口：
      query_effect_target_cells
      get_derived_cell_layer_report
      get_effective_stat_value
   -> 零命中

3) gdext 侧的 bind_methods 里搜 highlight / preview_cells / affected
   -> 零命中
```

## 2. 理念 UI 是存在的，但它不读派生层

| 文件 | 理念相关引用数 |
|---|---:|
| `country_panel.gd` | 19 |
| `ideology_card.gd` | 15 |
| `ideology_art.gd` | 9 |
| `ideology_level_meter.gd` | 3 |
| `ideology_detail_tooltip.gd` | 2 |

**它们用的是卡片/等级/需求的展示数据，不是「这张卡影响了哪些地块」。**

## 3. 所以这一项的正确说法

| 说法 | 准确性 |
|---|---|
| 「UI 高亮验收未做」 | ❌ 会让人以为功能在、只是没测 |
| 「**方案要求同步的高亮 UI 在代码里不存在**」 | ✅ 准确，且可操作 |

**方案 §12/§18.4 里的「UI 同步」指的是一个从未被实现的界面能力**：
把 `query_effect_target_cells`（或派生层的逐格贡献）画到地图上，让玩家看到「这张卡影响哪些格」。

**接口是有的**（`query_effect_target_cells` 已被 8 个夹具使用），**缺的是 UI 侧**。

## 4. 两个可选的处置（需决策）

| 选项 | 做法 |
|---|---|
| **A. 实现它** | 在地图上加一层高亮，数据源用 `query_effect_target_cells`（已存在、已测），或 `get_derived_cell_layer_report()` 的逐格贡献 |
| **B. 从验收范围里去掉** | 承认本方案只交付运行时与数据，UI 另立项 |

**我没有实现它**：这是玩家可见的界面功能，涉及美术与交互设计（`ui-art-direction` 那类工作），
不是「跑个夹具」能交付的；而且方案 §1.3 已声明本方案不交付平衡/表现层。

## 5. 对 §18.4 那一项的影响

「native docs、架构边界、skill、内容文案与 UI 同步」现在是：

| 子项 | 状态 |
|---|---|
| native docs | ✅ 9/9 |
| 架构边界 | ✅ |
| skill | ✅ 3/3 |
| 内容文案 | ✅ 194 处已落生成器（M5-59）|
| **UI 同步** | ⚠️ **目标 UI 不存在**（接口有，界面无）|

**它仍然只能算「部分」**，但缺的理由从「没做」变成了「没有可做的对象」。
