# M5-40 解封成本仍未能测量：我上一轮的结论是错的，但这次又卡在别处

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5-39](M5-39-kind14-uncap.md) 的「成本未测」项 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **仍未测到**。修正了上一轮的错误结论，但遇到新的、未定位的阻塞 |

## 1. 先纠正 M5-34 的错误结论

M5-34 我写：5 张 kind-14 卡的 tag 是**原生 tag**（由市场/家族/气候计算），合成夹具造不出来。

**这是错的。** `target_tag_dictionary.gd:128-129`：

```gdscript
_append(tags, by_name, _atom("cell.market", [_row(
    "cell.trade_events", OP_GTE, MARKET_TRADE_EVENTS * Q16_ONE)]))
```

`cell.market` 是**行定义的**，判据是 metric `cell.trade_events >= 24`，
而 `cell.trade_events` 是已发布的 metric（`effect_domain_catalog.gd:79`）——**metric 可以被覆盖**。

我当时看到的 `economy_runtime_family_buff.cpp:1133` 的 `{"cell.market"}` 是
**国家级 tag 计数槽**，与格级 tag 谓词无关。**我把一个无关的字符串匹配当成了判据来源。**

## 2. 于是这次走了正确的路

新夹具：`domain.metric_keys.find("cell.trade_events")` 拿 metric id →
`set_effect_metric_override_for_test(id, 40 * Q16)` → 装备 `autonomous_logistics_l1`
→ 读 `own_*` 与 `collect_*` 诊断。

## 3. 结果：卡确实装上了，但收集在 POD 阶段全失败

```
[k14] territory=400 truncations=0 matched=0 collect_entries=4 derived=0
[k14] own: owned=? rejected=? emitted=? last_tag=? last_cap=? branch=?   ← OWN 分支从未运行
[k14] collect: entries=4 targets_fail=4 collected_empty=0 pod_fail=4
[k14] commands: applied=4 rejected=0 | active ideas=1 locations=[1]
[k14] RESULT covered=0 collect_ms=0.0000 wall_ms=0.23
```

| 观察 | 含义 |
|---|---|
| `applied=4 rejected=0`、`active=1`、`locations=[1]` | **卡确实装备成功**（与 B5/B7 同形）|
| `own_*` 全是 `?` | **OWN_TERRITORY 分支从未运行**——卡没走到目标解析 |
| **`pod_fail=4`**（4 个模板全失败）| `family_effect_metadata_pod(program)` 返回 false → 全部留在 legacy 批次 |
| `targets_fail=4` | 同上 |

`ideology_runtime.cpp:2284-2287` 的注释是「No declarative program: the row stays on the
legacy batch」。所以这 4 个模板都没在编译后的 effect catalog 里找到 POD。

**我没能定位为什么。** 同一套 `configure_effects` + 装备序列在 B5/B7 里是工作的
（那里 `front cells=3200`），所以差异一定在我这个夹具的某处，但我没有找到。

**我没有猜一个原因写上去。**

## 4. 处置：删掉夹具，不留装饰

一个测不出任何东西、又永远失败的夹具，比没有更糟——它会污染回归集。

已删除 `ideology_kind14_uncap_cost_test.gd`。

## 5. 所以成本仍然没有数字

| 项 | 状态 |
|---|---|
| 代码：去掉 32 钳制 | ✅ 已实现 |
| 内容：5 张卡 `param0: 32 → 0` | ✅ 已实现 |
| 内容门禁：kind 14/15 不得 author cap | ✅ 已实现，**含负向对照** |
| **一次 resolve 实际慢多少** | ❌ **没有数字** |
| 机制上界 | 从 `32 × 环形` 变为 `领土格数 × 环形` |

## 6. 下次从哪里开始

诊断已经收窄到两点，按这个顺序查最省力：

1. **先看 `collect_entries=4` 是不是开局理念**。若那 4 个模板就是开局自带的理念
   （而非我装备的卡），那么「我的卡没进 `active_templates`」才是主因，
   与 POD 无关。最快的判据：把 `_persistent_templates` 的 `definition_key` 打出来。
2. 若卡确实在 `active_templates` 里而 POD 失败，再查
   `effect_program_key(templ.definition_key)` 与本夹具编译出的 effect catalog 的
   `program_keys` 是否对得上。

**第 1 步能一步排除一半可能，而它只需要加一行打印。**

## 6.1 已确认的部分（静态侧是好的）

用覆盖率脚本内部的 `build_facts()` 逐卡查了判定：

```
gentry_patronage_l3_ring     kind=14  backend=DerivedCell  reason=-  param0=0
refrigeration_l3_ring        kind=14  backend=DerivedCell  reason=-  param0=0
autonomous_logistics_l1      kind=14  backend=DerivedCell  reason=-  param0=0
autonomous_logistics_l2      kind=14  backend=DerivedCell  reason=-  param0=0
autonomous_logistics_l3      kind=14  backend=DerivedCell  reason=-  param0=0
```

| 项 | 状态 |
|---|---|
| 5 张卡静态判定为 DerivedCell | ✅ |
| 5 张卡 `param0 = 0`（内容改动生效）| ✅ |
| 无 `unresolved_definition` 之类的理由 | ✅ |

**所以「解封」在静态侧是完整落地的。** 缺的只是运行时的成本数字。

## 6.2 一个我查了但用错字段的线索

我怀疑「静态说派生、运行时 POD 失败」，于是去查编译后 catalog 的 `program_keys`：

```
[p] ok=true program_keys=0
[p] ideology.effect.autonomous_logistics_l1  present=false
```

**但这不能说明问题**：`program_keys` 为 0 是因为字段选错了——B5/B7 在同一份
`compile_native_catalog()` 下派生层是工作的（`front cells=3200`），
所以 POD 解析机制本身没问题。

**我没有把这个 0 当成「POD 缺失」的证据。**

## 7. 本轮的真实价值

- **纠正了我上一轮的一个错误结论**（「原生 tag」→ 实际是行定义在 metric 上）；
- 把阻塞点从「tag 不可达」推进到「POD 解析失败」并留下了确切的诊断字段；
- **没有编造成本数字**，也没有留下一个测不出东西的夹具。
