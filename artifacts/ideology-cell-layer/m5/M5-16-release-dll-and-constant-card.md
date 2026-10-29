# M5-16 release DLL 构建与真实测试 + 两种卡片形态都与解释器对照

| 项目 | 内容 |
|---|---|
| 里程碑 | [§18.4](22-cell-program-cap-removal-plan-v3.md) 工程证据 / §18.2 第 1 项 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **release DLL 构建通过并在 7 个 fixture 上真实跑过**；**常数卡也已完成与解释器的对照** |

## 1. release 构建

```
scons platform=windows target=template_release dev_build=no -j8
scons: done building targets.   exit=0
```

| DLL | SHA256 前 16 | 字节 |
|---|---|---:|
| `dots_ext_annual_v1.windows.template_debug.x86_64.dll` | `35e62122ab7371bb` | 14,173,184 |
| **`dots_ext_annual_v1.windows.template_release.x86_64.dll`** | **`c073f81ab348ec76`** | **12,168,192** |

## 2. release 构建暴露了我引入的一个缺陷

第一次 release 构建报：

```
warning C4715: building_context_ready_for_test: 不是所有的控件路径都返回值
```

`economy_runtime_family_buff.cpp` 里那个诊断函数**少了 `return out;`** —— 我上一轮编辑 `ready` 赋值时
把紧随其后的 `return out;` 一起吃掉了。

**一个返回未定义数据的诊断，比没有诊断更糟**（它会给出随机的 `ready`）。已修复，debug/release 都不再报警。
顺带修掉一处被早前编辑拼成一行的函数签名（`cell_country_slot`）。

**这个缺陷只有 release 构建才会报** —— debug 构建不报 C4715。这说明**两种构建都要跑**，不是形式要求。

## 3. release DLL 上真实跑测试

把 release 内容换到 debug 文件名下（备份原文件），跑 7 个 fixture：

| fixture | debug | **release** |
|---|---|---|
| oracle_cross_check | 12 / 0 | **12 / 0** |
| B7 | 22 / 0 | **22 / 0** |
| B8 | 18 / 0 | **18 / 0** |
| B10 | 16 / 0 | **16 / 0** |
| x1b | 142 / 0 | **142 / 0** |
| cell_layer_merge | 20 / 0 | **20 / 0** |
| effect_metric_publish | 268 / 0 | **268 / 0** |

**检查数逐一相同，失败数同为 0。** 之后已恢复 debug DLL（校验 `35e62122ab7371bb` 与备份一致）并用一个 fixture 复验。

## 4. 常数卡也完成了与解释器的对照

M5-14 的 oracle 只覆盖 **ramp 卡**。常数卡在收集器里走的是另一条分支
（`add`/`factor` 来自程序幅度，不做逐格采样），所以「数值正确」这个声明原本只覆盖了两种形态中的一种。

B7 新增：

```
[B7] constant card: interp=3277 -> 0.05000305   derived_add=0.05000305
```

`public_hygiene_l1` 的指令流是 `CONST 3277 -> EMIT`，所以解释器给 3277，而派生贡献是
**`3277 / 65536` 精确相等**。

B7 因此从 20 → **22 checks**。

## 5. 现在「数值正确」覆盖到哪

| 形态 | 证据 | 结果 |
|---|---|---|
| **ramp 卡**（24 个 kind-12）| oracle 12 检查，3 个点 `delta = 0`，含 MIN 钳位 | **精确相等** |
| **常数卡**（其余 241 个）| B7 的 `derived_add == interp/Q16` | **精确相等** |
| 多国、重叠、宽领土 | B8 18 / B10 16 / B7 22 | 结构正确 |

## 6. 对 §18 的影响

| 项 | 修复前 | 现在 |
|---|---|---|
| §18.4「debug/release 构建有完成日志、新 DLL 身份与真实测试」| 只有 debug | **已完成** |
| §18.2 第 1 项「同输入对照」| 仅 ramp | **ramp + 常数两种形态** |

## 7. 局限

- release 只在 **7 个** fixture 上跑过，不是全部 22 个。
- release 性能未测（只测了 debug）。
- 常数卡的对照只有一张卡（`public_hygiene_l1`），不是全部 241 个。
- 仍未在真实生成世界上验证。
