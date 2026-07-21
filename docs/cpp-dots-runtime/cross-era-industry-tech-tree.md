# 跨时代产业科技树

本文是经济目录的内容权威说明，配合 `cross-era-economy-content.md` 使用。运行时仍只读取
`tech.*` bitset；时代名称只用于设计、UI 分组、审计和文档，不参与 NativeEconomyRuntime 公式。

## 总体原则

- 基础食品、基础布料、基础工具必须在早期可得，后期通过升级族提高效率和投入复杂度。
- 工具品质固定为打制石器 1、青铜工具 2、通用金属工具 3、精密工具 4。高品质可服务旧配方；古典至封建至少要求 2，探索至原子至少要求 3，信息/AI 至少要求 4，低品质工具不能反向驱动先进生产。
- 信息时代以前发现的每种 good 至少有两种生产方式；后续方法复用同一 good，并加入当代工具、能源或控制投入，不复制终端物资。
- 自然资源只表达地形/生态容量或确实有地区分布与科技门槛差异的对象。牛、羊、猪、马不再是自然资源；`pasture` 表达畜牧容量。
- 淡水不进入经济配方。河湖供水和公共事业以后单独设计，不作为面包、米食、饮料等物资的隐藏投入。
- 鱼类保留粗粒度链条：`marine_fish -> fish`；淡水捕鱼由 `freshwater_fish` 湖泊/湖岸资源和淡水捕鱼营地表达。
- 野生动物保留为早期生态资源：`wild_game -> game_meat/raw_hide/fur`，由 `stone_age_hunting_camp` 产出，农业时代后重要性下降。当前石器营地有 2 个共同经营业主岗位，日产 `4846/59/30` GOODS_SCALE 的野味、生皮和毛皮；该组数值比 2026-07-21 基线提高约 30%，用于覆盖猎人现金生活支出，同时保持副产品受本地需求约束。`715` 的野生动物扣减使用独立资源单位，不能直接解释为商品重量转换率。
- 雇佣关系随时代复杂化：自营/家庭劳动 -> 学徒和行会 -> 地主/农奴/契约劳工 -> 工业工人/技师/工程师/经理。

## 时代表

| 时代 | 科技标签 | 新引入链条 | 深化旧链条 | 劳工关系 |
|---|---|---|---|---|
| 石器时代 | `tech.hunting`, `tech.gathering`, `tech.stone_knapping`, `tech.fire_control` | 采集植物、野生动物、海鱼、木材、石材、燧石、打制石器、公共火塘 | 家庭手织棚提供低效布料；狩猎营地同时产出肉、皮、毛皮 | 公共火塘/手工业由 artisan 经营；采集由 forager/hunter/fisher 自营 |
| 青铜/早期农业 | `tech.pottery`, `tech.bronze_casting` | 旱作/水田/牧场容量，地域原粮、畜牧产品、陶器、铜锡青铜 | 原粮由统一厨房产 `prepared_staples`；面包房直接接受合理谷物候选；牧场产肉、皮、乳、毛 | 自耕农、牧民、工匠、学徒、早期地主/依附劳工 |
| 古典时代 | `tech.writing`, `tech.masonry` | 早期铁矿、铁制工具、纸草、手稿、砖、石灰、玻璃、金银匠、酿造 | `tools` 从本时代起表示铁/钢等通用金属工具；石作直接产 `construction_components`，不再经过切石/精砌石 | 工匠作坊和少量雇佣帮工 |
| 封建时代 | `tech.manuscript_culture`, `tech.guild_organization` | 轮作小农、行会织造、裁缝、鞋匠、华服、精美家具 | 亚麻、棉、羊毛直接织成 `cloth`，再分流 clothing、footwear、fine_clothing | 地主/农奴、地租代理、行会师傅、学徒、熟练工 |
| 探索时代 | `tech.oceanic_navigation`, `tech.printing_press` | 棉花、橡胶、香料、药草、碎布造纸、印刷、蒸馏、远洋船 | 纸张在本时代可启动；盐、包装和纸不再依赖现代工厂 | 种植园契约劳工、运输工、城市雇工 |
| 启蒙时代 | `tech.experimental_science`, `tech.precision_engineering` | 炸药、工业化学品、罐藏食品、精密工具、科学仪器、机械零件 | 金属工具使用质量门槛；新化学品深化既有皮革、纸张和机械 | 研究员、工程师、技师雏形 |
| 蒸汽时代 | `tech.coke_smelting`, `tech.steam_power` | 焦炭钢铁、蒸汽机、铁路、水泥混凝土、工业造纸、机械织造、早期油井和矿物润滑剂 | 铁矿 + coal/coke 直接炼钢；机器零件使用独立工业润滑剂；主食、面包、畜牧、纺织升级为工厂 | 工业工人、经理、工程师、工业资本家 |
| 电气时代 | `tech.electrification`, `tech.radio`, `tech.electrochemistry` | 电力、电机、铝、电化学、化肥、炼油、汽车、家电、无线电 | 电力成为新生产方式的互补输入；集约农场消费化肥，旧产业进入电气化档 | 技师/电工/经理并存 |
| 原子时代 | `tech.geological_prospecting`, `tech.advanced_metallurgy`, `tech.nuclear_fission` | 战略矿产、稀土金属、核燃料、核电、医用同位素 | 矿业从普通矿带深化到勘探门槛和战略矿产 | 高技能工程、研究和管理岗位 |
| 信息时代 | `tech.digital_computing`, `tech.networked_computing` | 半导体、计算机、通信设备、合成橡胶、合成纤维 | 合成纤维直接进入织造并回接 `cloth -> clothing/fine_clothing`；后期以控制和效率深化旧产业 | 技师、工程师、经理、研究员 |
| AI 时代 | `tech.machine_learning`, `tech.autonomous_systems` | 先进芯片、自主系统 | 电子和机械链深化到高端自动化终端品 | 高技能研发和自动化产业岗位 |

## 关键升级族

| 产业族 | 层级 |
|---|---|
| `subsistence_food` | `gathering_ground -> subsistence_farm -> three_field_smallholding -> improved_smallholding` |
| `household_cloth` | `household_weaving_shelter -> household_loom -> cottage_weaving -> improved_domestic_loom` |
| `livestock_husbandry` | `pastoral_camp -> manorial_pasture -> ranching_station` |
| `staple_processing` | `staple_kitchen -> staple_food_plant`，五种原粮共享 `prepared_staples` |
| `bread_baking` | `bakery -> bread_plant`，谷物在同一输入槽内按配方效率替代 |
| `meat_processing` / `dairy_processing` | `slaughterhouse -> mechanized_slaughterhouse`, `creamery -> dairy_products_plant` |
| `paper_making` | `rag_paper_workshop -> paper_plant`，后者直接使用 logs/fiber + chemicals |
| `textile_weaving` | `guild_weaving_house -> textile_mill -> cloth_plant -> synthetic_textile_mill`，各档都产 `cloth` |
| `garment_making` / `fine_clothing` | `tailor_shop -> clothing_plant`；`court_tailor -> fine_clothing_plant` |
| `fine_furniture` | `cabinetmaker_workshop -> fine_furniture_plant` |
| `beverages` / `jewelry` | `brewery -> distillery -> beverages_plant`；`goldsmith_workshop -> jewelry_plant` |
| `metal_toolmaking` | `iron_tool_workshop -> tools_plant`，两者都产 `tools`；前者用铁矿与原木，后者用钢材与木材 |
| `fish_canning` | `canning_workshop -> canned_fish_plant`；启蒙时代出现罐藏，蒸汽时代进入工厂化 |

## 退役与合并

- 自然资源退役：`cattle`, `sheep`, `pigs`, `horses`, `fresh_water`。
- goods 退役：`cattle`, `sheep`, `pigs`, `raw_water`, `clean_water`, `beef`, `mutton`, `pork`。
- 冗余链 goods 退役：`flour`, `rice_food`, `corn_food`, `potato_food`, `wood_pulp`, `pig_iron`,
  `flax_yarn`, `cotton_yarn`, `textile`, `cut_stone`, `dressed_masonry`。
- 新终端 goods：`prepared_staples`, `fine_clothing`, `fine_furniture`。
- 建筑退役：物种级采集建筑、三种肉类工厂、净水厂、野生动物自动采集建筑。
- 保留 `horses` 作为前工业交通与上层娱乐 good，由青铜时代 `horse_breeding_camp` 和封建时代
  `horse_breeder` 使用 `pasture` 容量生产；不再占用 DataCore 自然资源 slot，也不生成后工业养马升级建筑。
- 旧战略矿物拆分资源 `uranium_ore`, `nickel_ore`, `platinum_ore`, `lithium`, `cobalt_ore`,
  `natural_graphite` 已折叠进 `rare_earth -> rare_earth_ore -> rare_earth_metals` 链，DataCore
  reserve/extra-change slots 同步删除。

## 当前目录规模

当前生成目录为 `31 resources / 120 goods / 261 production-method buildings / 33 professions / 18 needs / 8 consumption plans`。同一物资的后续生产法复用原 good ID；建筑代表有宏观意义的生产方式，不是为时代凑数的同名升级或新增转手中间品。马匹只保留两个前工业生产阶段，不随通用升级生成器延伸到后工业时代。
各时代新增建筑数为 `12 / 25 / 17 / 23 / 14 / 12 / 55 / 36 / 16 / 19 / 30`。解锁密度服从实际技术变迁，蒸汽与电气革命是集中扩张点；不再以“每时代至少若干建筑”的数量门槛制造低份额产业。持续产业逐代获得新方法，边缘产业在显式终止时代后由既有建筑继续运行、被其他产品吸收或退出宏观呈现。
32 个职业映射到 survival、agrarian、extractive、industrial_worker、artisan、technical、merchant、owner
八套原型；每个 need 最多八个 variants。旧 PKEC catalog
存档会因 catalog mismatch 明确拒绝恢复，不做静默 ID remap。
