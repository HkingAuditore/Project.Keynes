# M5-59 本会话最重要的发现：M2 的核心交付从未进入生成器，一次重新生成就会撤销

| 项目 | 内容 |
|---|---|
| 类型 | **交付持久性缺陷**（不是运行时缺陷，但后果更大）|
| 触发 | 核查方案 §12.1「生成器是唯一作者源，不手改生成结果」这句话 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结论 | 修好了。现在重新生成**逐字复现**手改结果 |

## 1. 我是怎么发现的

我在回答「还缺什么」时去读 §12.1，看到第 815 行：

> 「生成器是唯一作者源，修改后重建 `.tres`，**不手改生成结果**。」

**而 D3 的内容修复（194 处文案）是我手改 `.tres` 的。** 于是我跑了一次生成器，验证它会不会被覆盖。

## 2. 结果：不只是文案被覆盖

```
运行 generate_ideology_catalog.py 之后：
  -target_selector_param = PackedInt32Array(0, 0)
  +target_selector_param = PackedInt32Array(32, 0)      ← 194 处被还原
```

**M2 的核心交付「取消 32 目标格上限」只存在于手改的 `.tres` 里，从来没进过生成器。**

也就是说：

| 一个动作 | 后果 |
|---|---|
| 任何人跑一次 `generate_ideology_catalog.py` | **194 张卡的上限回来了** |
| 之后跑内容门禁 | `cap_removed` 12 检查会失败 |
| 但如果不跑门禁 | **这个撤销是静默的** |

**这比任何运行时代码缺陷都危险**——代码缺陷会被测试抓到，而「交付物能被一条命令静默抹掉」不会。

## 3. 根因：发射器写了 32 而没有映射

`generate_ideology_catalog.py::_selector_param_line`（原 `:5040-5061`）：

```python
if <kind 16>:
    pack_source_count(item.selector_cap if item.selector_cap != 32 else 0, ...)  # 有 32→0
    return f"target_selector_param = PackedInt32Array({packed}, 0)\n"
return (f"target_selector_param = PackedInt32Array("
        f"{item.selector_cap}, {item.selector_param1})\n")                        # ← 原样写 32
```

**kind 16 那条路径有 32→0 映射，非 kind-16 那条没有。** 而 `Prog.selector_cap` 的默认值就是 `32`（`:1616`）。

更糟的是 `:8069-8074` 还有一条自检**把这个行为钉死了**：

```python
if union_line != "target_selector_param = PackedInt32Array(32, 7)\n":
    raise SystemExit(...)
```

## 4. 修复

| 位置 | 改动 |
|---|---|
| `_selector_param_line` | 对无上限 selector，`selector_cap == 32` 时写 **0** |
| 新增 `UNBOUNDED_CELL_SELECTORS = frozenset((12, 14, 15, 16))` | 镜像 `selector_cell_cap.h` 的判定 |
| 自检 | 改为要求 `PackedInt32Array(0, 7)` |
| 位布局注释 | `0 = default 32` → `0 = NO cell cap` |

### 我差点又改错：把 kind 17 也映射成 0

我最初把 17（FAMILY_OWNED）也放进集合，依据是 `selector_cell_ceiling` 对它有 `kSelectorNoCellCap`。

**内容测试立刻报错**：

```
[FAIL] default ideology effects validate: ideology_effect_family_selector_param_invalid
```

原因：kind 17 的 `param[0]` 不是格上限，而是**家族数量上限**，运行时是
`std::clamp(param[0], 1, SELECTOR_MAX_CELLS)`——**0 会被钳成 1 并被校验器拒绝**。

已把 17 移出集合，并把这个理由写进注释。

**这是「内容测试抓到我改过头」的一次，我把它记在这里，因为它正好说明为什么要有内容门禁。**

## 5. 文案的源头修复（§12.1 要求，从未落地）

`player_summary` 的尾部（原 `:1840-1842`）：

```python
result += f"；最多影响 {item.selector_cap} 个目标地块"      # 所有 cell 类都加
if item.duration_days > 0:
    result += f"；持续 {item.duration_days} 天" + ("，可刷新" if ... )
```

按 §12.1 的三条要求改：

| §12.1 要求 | 落地 |
|---|---|
| 「文案删除 target 32」| 只对 kind 6/7 保留「最多影响 N 个目标地块」；kind 12 改为「作用于全部领土格」；14/15/16 不加 |
| 「环并集卡同时去掉技术性『最多计入 32 个来源』」| `SEL_TAG_SOURCE_R1/R2` 分支删掉该句 |
| 「来源计数卡继续显示每目标最多计入几个来源」| kind 16 的 `{item.cap}` 那句**保留**（它说的是 3，不是 32）|
| 死字段文案 | 持续时间句改为按 **`lifecycle == 1`** 判断，而不是 `duration_days > 0` |

最后一条是 `maritime_insurance_l1/l2/l3` 的根源：它们 `lifecycle=0` 但 `duration_days=30`，
旧代码按 `duration_days` 判断，于是三张永久卡都写着「持续 30 天，可刷新」。

## 6. 验证：生成器现在逐字复现手改结果

```
gen exit=0
(0,0)  = 199      (32,0) = 15      ← 与手改文件完全一致
作用于全部领土格     194
影响 32 个目标地块     0
持续 30 天             0
最多计入 32 个来源     0
```

| 检查 | 结果 |
|---|---|
| 内容门禁（7 条）| **7/7** |
| `ideology_content_test` | **67 / 0** |
| 回归 10 个夹具 | **全绿**（x1b 142、B7 27、B8 18、B10 16、B11 9、oracle 19、tag_source 106、cost 7、B5 9）|

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `tools/ideology/generate_ideology_catalog.py` | 发射器映射 + `UNBOUNDED_CELL_SELECTORS` + 三处文案门 + 自检 + 注释 |
| `data/ideologies/default_ideology_effects.tres` | 由生成器重建（不再是手改）|

## 8. 教训

**「生成器是唯一作者源」这句话如果只写在文档里，它就不会被执行。**

本方案有两处内容改动（M2 的 194 个 cap、D3 的 194 处文案）都是直接改输出，
**其中一个恰好是方案的核心交付**。我是在回答「还缺什么」时才顺带核到它的。

**可复用的检查**：任何「改了 `.tres` / 生成物」的交付，必须做一次
「跑生成器 → 看 diff 是否为空」。**diff 为空才算真的落到了作者源。**
