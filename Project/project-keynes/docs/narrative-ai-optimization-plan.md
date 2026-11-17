# 叙事 AI 重构方案：从「事件作者」退回「文本层」

状态：P2（城内部分）已实施，其余待评审
范围：`scripts/narrative/`、`scripts/narrative/ai/`、`scripts/ui/components/narrative_chronicle_panel.gd`

---

## 实施进度

### 2026-11-17 已完成：城内 AI 事件（scope = CELL）

按「先把城内做好」的决定，落地的是**上下文补强 + prompt 重写**，**没有动触发频率**。

| 改动 | 文件 | 效果 |
|---|---|---|
| AI 路径打开 cohort 明细 | `narrative_event_service.gd::_request_ai_generation` | 此前 `sample_cell_context` 未传 `include_cohort_details`，职业构成、温饱缺口、失业率、主 cohort 职业全是默认空值——prompt 只能写「满意度若干」 |
| 脉冲通道命中后补采 | `narrative_event_service.gd::run_pulse_sample` | 掷骰只用轻量字段（紧缺/溢价/满意度/气候），命中后才补采明细与邻城，避免为九成会被拒的骰子跑 3–6 次原生查询 |
| 邻城概况采样 | `narrative_context_sampler.gd::_sample_neighbor_settlements` | 最多三处相邻己方聚落，取名称 / 人口 / 最紧的一项商品，让事件能写「邻城也在涨」 |
| 人的构成接入 prompt | `narrative_ai_prompt_builder.gd` | 主要生计（几分之几）、民生压力（养不活家 / 没活干）、人数最多那群人的现钱 |
| 本城在本国的位置 | 同上 | 领土格数 + 本城人口，给模型「大城 / 边邑」的尺度感 |
| 正文 20–50 → 60–140 字 | 同上 | 对齐手写事件（`war` 目录均值约 130 字） |
| 解除文学禁令 | 同上 | 保留：禁专名、禁阿拉伯数字、禁读数、禁现代词汇；解除：禁修辞、禁场景、禁对白 |
| 新增写人规则 | 同上 | 「写人不写名」（用身份：管库的老吏、接生的、守门的）、「写物」（至少一样具体的东西）、「按行当写难处」 |
| 三条 few-shot | 同上 | 从 handwrite catalog 抽疫病 / 工程 / 市井三段，人名地名已替换为泛称 |
| 禁止照抄快照数字 | 同上 | user prompt 末尾显式声明：快照数字只作判断依据 |
| 正文上限 160 → 220 | `narrative_ai_validator.gd` | 原 160 按「两行事实」定的，会把 60–140 字的正常叙事腰斩 |
| prompt 快照工具 | `tools/narrative_prompt_probe.gd` | 改完 prompt 跑一次，肉眼确认模型看见了什么 |

验证：`narrative_event_runtime_test` **108 checks / 0 failures**（新增 11 条断言：生计、民生压力、邻城、few-shot、禁令已移除、长正文不被截断、endpoint 归一化 5 条）；`narrative_ui_screenshot_qa` 5 张截图正常，长正文有多行容器承载。

**未做**：触发频率（`ai_min_request_gap_days` 仍是 60）、局面改写（P1）、跨尺度判定。

### 2026-11-17 追加：年度纪事（AI 写报告的末章）

比事件系统更适合作为第一步：年度报告一年一次、数据已由 native 定稿、玩家必读，
而 AI 只需要把定稿的数字写成一段史笔——**改不了任何数值，也不可能造成模拟偏差**。

**数据流**

```
native 年度快照
  → AnnualReportViewModel.build()            # 九章数据 + full_text，全部格式化完毕
  → AnnualChronicleScribe.build_brief()      # 压成「史官简报」：KPI + 评级 + 每章至多三条 details
  → request_text()（不套事件 JSON schema）    # 纯文本通道，与事件生成共用凭据/endpoint/超时
  → 落盘 user://annual_chronicle/v1_<id>.txt
  → 开卷时 append_chronicle_chapter()        # 第十一章「纪事」
```

**时序**：`report_ready` 时就预生成。从报告就绪到玩家开卷通常隔几秒以上，异步请求基本赶得上。
赶不上则本次不显示，报告与今天完全一致——宁可少一章，也不要用空章或加载态打断阅读。

**关键取舍**

- **brief 不给 `full_text`**：那里面有整段原始账目（1/10000 货币、Q16 比例、月度附表），
  模型读到裸数字只会照抄或算错。只递已格式化的句子。
- **数字做成定性描述**：简报里出现的是「人口 四十六」这类格式化串，而 prompt 要求写成「添了不少丁口」。
  「禁止照抄数字」的禁令不可靠，不给它可抄的数字才可靠。
- **不复述评级**：第一版把「岁末考评乙上」写进正文，读起来像衙门批语不像史书，已明令禁止。
- **禁止逐章罗列**：第一版把九章梗概逐条改写成句子，读起来是清单。
  加了一句「宁可只写透渠和粮，也不要顺带提一句陶土」，输出立刻从一段流水账变成三段各有纵深。

**新增字段与接口**

| 项 | 说明 |
|---|---|
| `AnnualChronicleScribe.build_messages(model)` | 静态，可离线验 prompt |
| `AnnualChronicleScribe.build_brief(model)` | 静态，简报口径 |
| `AnnualReportViewModel.append_chronicle_chapter(model, text)` | 幂等；空文本不造章；同步并入 `full_text` |
| `chapter.details_ink` | 为真时 `AnnualSection` 用墨色 17px 正文，而非账目附注的灰字 15px |
| `NarrativeAiClient.request_text()` | 纯文本通道，无 `response_format`，超时 30s |
| `NarrativeAiClient.extract_chat_content()` | 从 Chat Completions 响应里取 content，事件与纪事共用 |

**实测（deepseek-flash，一百八十七字）**

> 是年开春，新聚落立起来，夯土为墙，搬进去的多是佃户；另有一处旧聚落升了格，换了界石。丁口添了不少，添的多在佃农家里。
>
> 铁匠铺的炉子整年没熄。打出的铁器上了市，实付的工钱却只有那么些，铁匠蹲在门槛上数完，揣进怀里，又进去拉风箱。
>
> 入冬，管仓的清点陶土，说挖得狠了，堆场上剩的不多，土坯得省着用。市面上的货不齐整，粮行的、押车的都在门口等。新册子压在旧册子上面，边角还空着。

**顺带修掉的一个显示错位**：滚到底时，进度轨按「视口 30% 处的横线」反推当前章，
而末章内容短、顶不到那条线，于是玩家在读第十一章、目录却高亮第十章。
已改为「滚到底即认定末章」。

**已知局限**：首次遇到某一年且开卷极快时可能还没生成（下次开卷命中缓存）；
历史报告同样走缓存，但缓存是在该年就绪时写的，早于本功能的旧年份不会有。

### 顺带修掉的一个静默失败

`user://settings.cfg` 里的 `ai_llm_base_url` 可能是裸 host（实测就是 `https://api.deepseek.com`）。
`NarrativeAiClient` 直接拿它当 endpoint POST，返回 **404**，而调用方只看到一行 `ai_http_error`——
看起来像「服务不可用」，实际是路径没补全。**只要用户按 host 填，AI 事件就一条都不会生成。**

修法：`normalize_llm_endpoint()` 只补三种明显不完整的形态（裸 host / 尾部斜杠 / 只填到 `/v1`），
已有自定义路径的一律原样放行——内网网关常用 `/openai/v1/chat/completions`，猜错比不猜更糟。

### 实测样例（2026-11-17，deepseek-flash，同一条快照连跑三次）

快照：柳湾，三百八十口，佃农四成，二成养不活家，粮价一点四二倍，在战，邻城上河渡缺粮。

> **官价征粮**
> 一辆牛车停在{settlement_name}的粮行门口，车辕上绑着一根缠红布的木牌。军需官摊开一卷盖印的文书，说要按官价取粮，官价比市面低四成。掌柜的算盘没动，伙计把仓门钥匙攥在手心，钥匙串上还挂着一块旧封条，是去年开仓时留下的。
>
> 照文书如数粜粮 → **粮车出城**：粮车装满，车辙压到河边。掌柜把官价与市价的差额记在册子边角，末尾画个圈。官钱三日后送到，伙计数到一半就捆上了绳子。
> 掺陈粮凑数 → **验粮的没细看**：验粮的掀开麻袋抓了一把，搓了搓就扔回去，说行。
> 摊派到佃户头上 → **按佃租册子摊**：各户照佃租册子摊，一家两斗。管账的提着斗沿田埂走，走到第三家天就黑了，借了盏油灯照着量完。

另两次分别写成「营里的粮册」（一百零九字）与「空车与种粮」（一百一十七字），
都落在佃农的具体难处上（种粮 vs 军粮），无专名、无阿拉伯数字，validator 均一次通过。

---

## 0. 结论先行

当前实现把 LLM 放在**结构层**（决定发生什么、后果多大），而把它的强项（写具体的人与物）用 prompt 逐条禁掉。
结果必然是可被查表替代的输出，且被 60 日节流压到几乎不出现。

重构方向只有一句：**把 LLM 从「事件作者」降级为「文本层」——它不决定任何数值，只决定同一件事读起来是什么样。**

这不是能力妥协，而是对齐业界已验证的形态（Dramamancer / Drama Llama / WhatELSE / Meaning Machine 全是这个形状）：结构归作者，LLM 管措辞。

---

## 1. 先测，再改（第 0 步，半天）

现在没有任何一局真实数据能回答「AI 事件到底占多少」。凭感觉改概率会走错方向。

新增 `tools/narrative_ai_report.gd`（headless，复用 `PK_AUTOPLAY_PROBE=1`）：

```bash
PK_AUTOPLAY_PROBE=1 <godot_console> --headless --path . --script tools/narrative_ai_report.gd
```

输出四个数：

| 指标 | 计算方式 | 判读 |
|---|---|---|
| `ai_event_share` | `chronicle[].is_ai_generated == true` / 总条数 | < 5% ⇒ 问题是「没出现」，优先 P3；≥ 15% ⇒ 问题是「不好看」，优先 P0+P2 |
| `ai_pool_flush_rate` | 出池展示数 / 入池总数 | < 30% ⇒ 生成的东西和状态对不上，白烧调用 |
| `text_length_ratio` | AI 事件 body 均长 / 静态事件 body 均长 | 用于确认「电报体」判断 |
| `effect_key_entropy` | AI 事件用到的 distinct `target_key` 数量 | < 6 ⇒ 选项确实没有分歧，P1 无效，先扩白名单 |

**这四个数决定后面做哪几个阶段。** 如果 `ai_event_share` 已经 20% 以上，第 3 节 P3 直接砍掉。

---

## 2. 护栏（整个方案不可越过的三条）

1. **AI 永不参与数值结算。** 所有效果由作者写死或由静态 catalog 决定。AI 的输出只能是文字。
2. **AI 永不负责任忆。** 世界状态存在 `story_flags` / `_chronicle` / 模拟侧，不存在模型的上下文里。任何「让模型记住上一件事」的设计都不做。
3. **AI 永不决定「发生什么」。** 事件的触发条件、权重、冷却全部留在引擎。模型不生成 `conditions`，也不生成 `effects`。

一句话：模型只被允许改字符串。

---

## 3. 四个阶段

### P0 — 编年史书写者（1 天，零风险，优先级最高）

**要解决的问题**：AI 完全不参与玩家真正会回看的地方。编年史现在只存标题与结果，读完没有任何画面。

**为什么零风险**：`resolve_active_offer()` 在 `_chronicle.push_front(record)` 时，数值已经全部结算完毕（`applied_effects_summary` 都生成好了）。此时再让模型写字，它已经改变不了任何东西。

**接入点**（已核实存在）：
- `narrative_event_service.gd:1347` 的 `record` 字典已含 `settlement_name` / `title` / `body_text` / `chosen_option_text` / `outcome_title` / `outcome_narrative` / `applied_effects_summary` / `date_text` / `day`
- 这是完美的输入契约，无需新增采样

**改动**：

1. 新增 `scripts/narrative/ai/narrative_chronicle_scribe.gd`
   - `request(record: Dictionary) -> int` 返回 seq；独立于事件生成的在途队列（不共用 `_pending_ai_requests`，否则会被 60 日节流卡住）
   - 独立 profile：`max_tokens ≈ 220`、`temperature 0.9`、不带 JSON mode（纯文本返回）
2. `narrative_event_service.gd`
   - 新增信号 `chronicle_prose_requested(payload)`，在 `push_front` 之后 emit
   - 新增 `apply_chronicle_prose(record_id: int, prose: String) -> bool`：按 `record_id` 回填 `record["chronicle_prose"]`，`chronicle_updated.emit()`
   - 回填失败（record 已被挤出）静默丢弃
3. `narrative_chronicle_panel.gd`
   - 显示优先级：`chronicle_prose` → `outcome_narrative` → `applied_effects_summary`
   - `chronicle_prose` 为空时表现与今天完全一致
4. 持久化：`pknr` 段的 chronicle 数组加一个可选键，缺字段回退（旧存档零迁移）

**prompt 要点**（与现有事件 prompt 完全不同，单独一份）：
- 输入：日期、聚落、事件标题、选择、结果标题、效果摘要（**只作事实依据，不许照抄数字**）
- 输出：**2–4 句、60–140 字**，允许具体的人与物、允许动作细节、允许留白
- 禁止：阿拉伯数字、百分号、专名（族名/人名/国名）、现代词汇、评价性总结（「这体现了……」）
- 关键：**这次不需要复用，所以可以写死具体细节**——这是它比事件生成更能出彩的根本原因

**验收**：
- `narrative_event_runtime_test` 加一条：scribe 失败时 `chronicle_prose` 缺失，UI 仍显示 `outcome_narrative`
- 模拟一致性测试逐位相同（因为不碰数值，理论上必然通过；跑一次确认没有副作用）
- 人工看 20 条，要求「比原文更像这个城里发生的事」≥ 15 条

---

### P1 — 局面改写（3 天，覆盖面最大）

**要解决的问题**：177 条静态事件玩两局就重复；而 AI 从零生成的质量下限守不住。

**做法**：不做「AI 新事件」，做「同一条事件的局势变体」。以作者原文为骨架，让模型只改「处境细节与语气」，不改动作结构。

**数据契约**：新增 `scripts/narrative/narrative_text_variant_store.gd`

```
key = "{event_id}|e{era_index}|{season}|{terrain_bucket}|{pressure_bucket}"
      pressure_bucket ∈ {calm, strained, crisis}   # 由满意度/紧缺/战事三档合成
value = {
  "body_text": String,
  "option_texts": PackedStringArray,
  "outcome_narratives": PackedStringArray,
  "generated_day": int,
}
```

存储：`user://narrative_cache/variants/{hash}.json`，内存 LRU 200 条，磁盘上限 600 条，超出按 `generated_day` 淘汰。

**触发时机**：`_push_offer()` 里，命中静态事件且该 key 缺失 → **后台请求，本次仍用原文**；下次同 key 命中时用变体。绝不阻塞弹窗。

**prompt 要点**：
- 输入：作者原文（作为骨架）+ 当前局势三档描述（不含数字）
- 任务：「保留原文的动作链与物象，替换不适配当前处境的细节与语气，长度±20%」
- 三条硬约束：不写专名 / 不出现阿拉伯数字与百分号 / 不新增或删除情节转折
- 明确告诉模型：**这是改写，不是创作**。质量下限由原文锁住

**为什么这个形状对**：`177 × 3 局势 = 531` 条可读文本，全部有作者兜底；而运行时从零生成 531 条的失败率会高一个数量级。

**验收**：
- 同一 `event_id` 在 3 种 `pressure_bucket` 下 `body_text` 差异率 ≥ 80%
- 数值行为与改前逐位一致（变体只替换字符串）
- 变体缓存缺失时游戏表现与今天完全一致（关键：不能因为网络失败导致事件不弹）

---

### P2 — prompt 重写（0.5 天，性价比最高）

**要解决的问题**：即使 AI 事件出现了，也被要求写成电报。

**改动**：重写 `narrative_ai_prompt_builder.gd::_build_system_prompt()`

| 现状 | 改为 |
|---|---|
| `body_text` 20–50 字 | 60–140 字（对齐手写 130 字均值） |
| 「只写条件、现状与影响，不写场景与修辞」 | 「写清楚谁在做什么、看见什么、东西是什么样子；不写判断与总结」 |
| 第 6 条「不得修辞、比喻、典故、感叹、场景铺陈与人物对白」 | 只保留「不得现代词汇、不得照抄数据读数」，删掉其余禁令 |
| 无范例 | **加 3 条 few-shot**，从手写 catalog 抽（war / plague / town 各一），人名替换为「某吏」「一个兵」 |

**关于 few-shot**：这是整份方案里单位成本最低的质量杠杆。手写事件的文风无法用形容词描述，只能给样本。注意挑选**不含专名**的段落，或先把人名替换掉再放进 prompt，否则会诱导模型编造人名。

**保留的禁令**（这些是真约束，不是为了省事）：
- 阿拉伯数字与百分号（`custom_label` 除外）
- 专名（池化复用会穿帮）
- 当日读数（温度写 `{temperature}`）
- 现代词汇

**验收**：20 条盲测（抹掉来源，问「哪条更像这个城里发生的事」），目标 ≥ 12 条判 AI 更佳。

---

### P3 — AI 事件通道重定位（2 天，可选，取决于第 1 节数据）

**如果 `ai_event_share ≥ 15%`：本节不做。** 问题不在频率，在质感，做完 P0/P2 就够。

**如果 `ai_event_share < 5%`：** 说明 AI 事件根本没来，但**不要简单调低 `ai_min_request_gap_days`**——那只会让简报体更频繁地出现，更烦人。

正确做法是**换通道**：AI 的产出不再直接进弹窗队列，而是进「风声层」：
- 输出不弹窗，写进 `story_flags` 的软标记（`rumor.*`），供静态事件的 `required_story_flags` 消费
- 或作为 `ADD_EVENT_WEIGHT_BIAS` 的来源，给对应 tag 加权
- 或作为编年史的旁注行（不进事件列表）

**好处**：不抢 `min_popup_gap_days` 的展示预算，所以请求间隔可以从 60 日降到 7 日，且可以用更便宜的模型。玩家感知到的是「世界在动」，而不是「又弹了一个框」。

---

### P4 — 度量与回归（1 天，贯穿）

- `tools/narrative_ai_report.gd` 固化为 CI 之外的手动检查项
- 每个阶段结束跑一次，记录在 `docs/` 同目录的表格里
- 回归项：`narrative_event_runtime_test`、`game_settings_service_test`、`save_repository_test`、`pause_menu_ai_settings_test`、`narrative_ui_screenshot_qa`

---

## 4. 排期与最小可行组合

| 阶段 | 工作量 | 依赖 | 风险 |
|---|---|---|---|
| 1. 量测基线 | 0.5 天 | — | 无 |
| P0 编年史书写者 | 1 天 | 基线 | 无（不碰数值） |
| P2 prompt 重写 | 0.5 天 | 无 | 无（只改文本质量） |
| P1 局面改写 | 3 天 | P0 的 client 复用 | 低（缓存缺失回退原文） |
| P3 通道重定位 | 2 天 | 基线数据 | 中（改触发语义） |

**只有 2 天的话：做 P0 + P2。**
这两个加起来不动任何数值路径、不改触发语义，但能同时解决「AI 缺席」和「写得干」两个体感问题——因为它们把 AI 挪到了玩家真正在读的那几行字上。

**P1 是覆盖面最大的长期投入，但不紧急**，因为它解决的是「重复感」，而重复感只有在内容量被玩透之后才会出现。

---

## 5. 不做清单（防止方案失控）

- ❌ **不要调低 `ai_min_request_gap_days` 来解决「感觉没用」**。频率上去、质量不变，只会更烦。
- ❌ **不要扩大 AI 的 `effects` 白名单来「让选项有分歧」**。分歧感来自后果类型不同，不是键更多。真要扩，扩的是静态事件的作者手写效果集，不是 AI 的权限。
- ❌ **不要让 AI 生成事件链**（`SCHEDULE_FOLLOWUP_EVENT` 由模型决定）。模型没有跨月记忆，链条必断。链只有作者能写。
- ❌ **不要做「AI 记住玩家上次的选择」**。记忆必须落在 `story_flags` 与编年史里，由 `required_story_flags` 消费，而不是塞进 prompt 历史。
- ❌ **不要把编年史重写做成同步阻塞**。弹窗关掉、时钟继续走，文字可以后到；到了再刷新面板。

---

## 6. 与业界做法的对应

| 本项目阶段 | 对应形态 |
|---|---|
| P0 编年史书写者 | LLM 只做表现层（商业侧最稳形态） |
| P1 局面改写 | Dramamancer 的 storylet + LLM 文本 adapt；WhatELSE 的抽象层级 |
| P2 prompt + few-shot | Meaning Machine 的 contextual snippets 与 retrieval |
| P3 风声层 | 作者结构 + LLM 提供软信号，不让 LLM 直接触发内容 |
| 全程不做 | AI Dungeon 式全自由生成（state 不落地，已公认失败） |

---

## 7. 一句话验收标准

改完之后，玩家在编年史里读到的那一段话，应该像出自写 `war` 目录的那个人之手，而不是像一份系统日志。
如果做不到这点，说明我们仍然在用 AI 填表。
