# M5-87 【重大缺陷】worker 权威下派生地块层**完全不产生东西**

| 项目 | 内容 |
|---|---|
| 触发 | 首次用**生产 worker 世界**（`WorldRuntimeHost` + `runtime_authority_domain_mask=0xFFF`）跑派生层 |
| 夹具 | `ideology_worker_authority_parity_test.gd` — **88 / 0**（它断言的是**失败的确切形状**）|
| 结论 | **32 上限取消的交付在 worker 权威配置下是惰性的（inert）** |
| 日期 | 2026-10-29，Asia/Hong_Kong |

## 1. 实测（我独立复跑，两次运行一致）

worker 拥有 ideology 域（mask `0xFFF`），卡片**已经装备且是活的**：

```
[CAPTURE/K3-A] day=14 installed=false gen=0 cells=0 contributions=-1
                sample_day=-1 covered(add)=0 covered(cut)=0
                rebuild_visits=8 confirmed=-1 eligible=-1
[K3][FINDING] worker authority: card live (locations=[1]) but the derived front is
               installed=false cell_count=0 contributions=-1
```

**同一份卡片状态、同一个世界**，把 ideology 域翻回主线程之后：

```
[CAPTURE/K2] installed=true cell_count=2 contributions=2 layer_generation=1
             covered(add)=1 格，add = 0.0500030518 = 3277/65536
```

**逐格对照（192 格 × 2 stat）**：

| 量 | worker | 主线程 |
|---|---:|---:|
| 覆盖格 | **0** | **2** |
| presence 不匹配 | **2** | — |
| add 不匹配 | **2** | — |
| `cell_count` | 0 | 2 |
| `contributions` | **−1** | 2 |
| `layer_generation` | 0 | 1 |

`max_abs_add_diff = 0.0800018311` —— **恰好是 `5243/65536`，卡片的授权 cut 值**。

**非空对照**：`[PARITY/k1-vs-k2]` 两次独立世界（同 seed）的对照是 **0 不匹配**，说明比较器本身是活的。

## 2. 为什么这不是我的改动造成的

| 证据 | 说明 |
|---|---|
| `rebuild_visits=8` | **分片确实在被 step** —— 不是「没跑」 |
| `confirmed=-1 eligible=-1` | §9.3 的门**从未设值**，而门把 `eligible < 0` 当作「没有基础」→ **门不拦** |
| `cell_count=0` | 所以是**采集阶段产出了 0 行**，不是被门挡住 |

**即：重建在跑、门没拦、但采集什么都没采到。**

而卡片状态是**可见的**（`locations=[1]`）。所以缺口在「主线程上的 ideology runtime 在 worker 权威下拿不到它需要的 effect/country 侧数据」——**这是权威架构的既有缺口，不是本轮引入的**。

## 3. 另外五条实测发现（同一个夹具，都有数字）

| # | 发现 | 数字 |
|---|---|---|
| **2** | **内建的 ideology parity 比较器是死的，不是滞后** | worker 提交了 15 天，而 `compared=0 / matched=0 / published=0 / skipped=0 / reason=""` |
| **3** | **分裂权威（ideology 主线程 + effect worker，mask `0xFEF`）无法完成装备** | 卡片始终不生效；B2 的 receipt 里 **13 次** `ideology_effect_transition_rejected` |
| **4** | **重启的 worker 不提升它的 mask 账本** | 翻到 `0xFEF` 后 `authoritative_domain_mask` 仍是 `0x000`，而写入方**确实**跟着请求走了（下次重建了 front）——测了两次 |
| **5** | ideology 域离开 worker 后世界很快故障 | **3/3 次**，故障码每次不同：`day_wait_peer_stall_timeout` / `market_shape_invariant_broken` / `unhandled_worker_exception`（day 19）——**报告为不稳定，未诊断** |
| **6** | **诚实的负结果**：mask `0xF8F` **是能起来的** | `worker_ready=true`、`reported_mask=0xF8F`、最终版 3/3；早期某版在它下面 day 3 就故障，**未能复现**，所以不声称该组合不可用 |

## 4. B2 场景：一条子句**按字面不可实现**

方案 §14.2 的 B2 = 「同 B1，worker」。B1 = **64 国** × 12 张在场卡。

**「64 国」被生产路径拒绝**：`NewGameConfig.MAX_FOREIGN_COUNT = 12`，
`foreign_count=63` 时 `from_dictionary()` 返回
`{"ok":false,"code":"foreign_count_out_of_range","message":"外国数量必须在 0 到 12 之间。"}`

**所以在天花板（13 国）上跑**，卡片子句不变（容量经 profile 提到 12，已验证 `ideology_capacity=12`）：

| 量 | 实测（32×16 真实生成 worker 世界，3/3 次）|
|---|---|
| 卡片 | 13 国 × 12 = **156 张**，其中 **13–26 张**是活的 |
| 派生 front | **`installed=false, cell_count=0`** ← 与发现 1 同因 |
| 节奏 | 21 天，**2914–3488 ms/天** |
| 交接滞后 | worker 的 `ideology_pod_committed_day = 9–10` vs 主线程 day 21 → **滞后 11–12 天** |
| **稳定性** | **每次都故障**：`day_wait_peer_stall_timeout`（`RUNTIME_DAY_STALL_PEER_FAULT_TIMEOUT_MS = 5000`），即使每天给 6×96 次 country-peer 服务 |

## 5. 这对 §18 意味着什么

| 项 | 之前 | 现在 |
|---|---|---|
| §18.1 四种权威组合 | **无证据** | **有证据了**：两个闸都被从代码读出并**计算而非假设**（`ClimateAuthorityPolicy.resolve` 的 6 格塌成 4 个判定；12 位 mask 里 `IDEOLOGY = 0x010`，且 `0xF7F` 仍然授予 ideology——它清的是 `GAMEPLAY_EFFECT` `0x080`）。**但其中一种组合是坏的** → **部分** |
| §18.2 主线程/worker 一致 | 部分（「worker 未验证」）| **已测且不一致**：covered 0 vs 2、`max_abs_add_diff = 5243/65536` → **仍是部分，但现在是「测过、坏了」而不是「没测」** |
| §18.3 B2 | 部分（「只剩 B2」）| **已测**：13 国（64 不可实现）、front 0 格、2914–3488 ms/天、滞后 11–12 天、**每次都故障** |
| 末段「主线程-worker parity」| 缺 | **实测缺失**，且不是滞后而是**完全没有** |

**「无证据」从 2 项降到 1 项**（只剩 execution contract 那个死字段），但**代价是发现了一个比「没证据」严重得多的问题**。

## 6. 这个缺陷的严重性

**方案 §1.1 的核心承诺是「理念永久地块效果取消 32 格限制」。**

**如果游戏把 ideology 跑在 worker 上，这个承诺完全不成立——派生层一格都不产生。**

而 `0xF7F`（**所有既有 ideology worker 夹具用的 mask**）**仍然把 ideology 留在主线程**，
所以**此前没有任何夹具能发现它**。这个夹具是第一个真正把 ideology 交给 worker 的。

**所以这不是回归，是一直没被看见的功能缺口。**

## 7. 我没有做什么

- **没有修它**：这需要改权威架构（主线程侧如何在 worker 拥有 ideology 时获得 effect/country 数据），**影响面远超本方案**。
- **没有把那个夹具写成「通过」**：它断言的是**失败的确切形状**（`covered=0/2`、`max_abs_add_diff=5243/65536`），**一旦有人修好它，那个夹具会红**——这是故意的。
- **没有诊断发现 5**（故障码每次不同，3/3 次但不可复现到单一原因）。

## 8. 建议的下一步（不属于本方案）

| 顺序 | 内容 |
|---|---|
| 1 | 弄清 worker 拥有 ideology 时，主线程的 `collect_effect_activations` 为什么采不到东西（`rebuild_visits=8` 说明它在跑） |
| 2 | 决定 ideology 是否**支持** worker 权威——如果不支持，就应该在配置层**拒绝**该组合，而不是静默产出空层 |
| 3 | 让 `authoritative_domain_mask` 在 worker 重启后正确提升（发现 4） |
| 4 | 修好或删除那个死掉的 parity 比较器（发现 2）——**一个永远报 0 的比较器比没有更糟** |
