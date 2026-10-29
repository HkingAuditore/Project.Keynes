# M2-4 relaxing both validators — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) 前置 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | GDScript + C++ 两层校验按种类放宽；`selector_authored_cell_ceiling` 拆分；19 checks 新测试 |
| 证据 | 回归回到基线 6 项，且 `parity` **失败数由 3 降到 1**（真实改善）|
| 结论 | 放宽已生效；**过程中把生产 catalog 弄坏了一次**，根因与修法见 §3 |

## 1. 本轮做了什么

| 层 | 位置 | 改动 |
|---|---|---|
| GDScript | `ideology_effect_definition.gd` | `selector_cell_ceiling()` 按种类；校验改用 authored 上限 |
| C++ | `effect_runtime.cpp:1005-1013` | 同样的按种类判断 |
| 纯头 | `selector_cell_cap.h` | 新增 `selector_authored_cell_ceiling()` |

新增测试 `ideology_effect_definition_ceiling_test.gd`（**19 checks**），把 GDScript 侧的上限表与 C++ 常量逐项对照——两份数值规则放在一起而没人校验必然漂移。

## 2. 我先把 catalog 弄坏了

只改 GDScript 后跑回归，失败从 6 项涨到 **10 项**，新增了 4 个原本通过的：

```
ideology_effect_instance_test      FAIL default ideology effect catalog validates
ideology_effect_override_test
ideology_tag_snapshot_stress_test
runtime_ideology_save_roundtrip_test
```

第一反应是「两层不一致」。我把 C++ 也放宽、重建 DLL 后**仍失败 10 项**，说明判断错了。

## 3. 真正的根因：把几何值当成校验上限

追到 catalog 校验失败，再查内容：

```
kind 6 (R1) 的 param[0] = 8        ← 内容写的
selector_cell_ceiling(6)   = 6     ← 我上轮定的几何值
8 > 6 → 校验拒绝 → 整个 catalog 编译失败
```

**这是一个真实的设计错误，不是实现 bug。**

`param[0]` 是**上限**，不是**预期格数**。R1 的走格最多返回 6 格，作者写 8 是完全合理的（那个 8 永远不绑定）。我却用「几何可达 6」去校验「作者声明的上限」，把合法内容判成非法。

同理 kind 7 写 18，而我的几何值是 18——刚好不冲突，所以只有 R1 暴露了问题。

### 修法：区分两个上限

| 函数 | 用途 | 有界种类返回 |
|---|---|---|
| `selector_cell_ceiling(kind)` | **运行时**用于压走格结果 | 几何值（R1=6、R2=18） |
| `selector_authored_cell_ceiling(kind)` | **校验**作者声明的 `param[0]` | 遗留 32（**不再收紧**） |

无上限种类的两者都是 `SELECTOR_NO_CELL_CAP`，那才是本方案要改的部分。

**关键洞察：** 校验上限只能**放宽**，不能因为引入了更精确的几何知识就顺手收紧。收紧会拒绝既有内容，而「取消 32 限制」的目标里从来没有「收紧径向扇出」。

## 4. 又一次两层不同步

先改 GDScript 后，C++ 仍是旧逻辑。虽然在修完 §3 之后两边都正常，但**中间态确实不一致**（GDScript 接受、C++ 拒绝）。

这不是巧合：两处校验跑在同一次编译的不同层，任何单边改动都会造成「一边通过一边拒绝」。我在两处代码注释里都写了「必须与另一侧保持同步」。

## 5. 回归结果

| fixture | M0 基线 | 本轮 | 判定 |
|---|---|---|---|
| 15 项中 6 项非通过 | 一致 | 一致 | 零变化 |
| **`runtime_ideology_parity_test`** | failures **3** | failures **1** | **改善** |

parity 的改善是真实的：M0 基线里 `uncompared=2`（两个权威跑在不同日历上，无法比较），本轮该失败消失，比较得以真正进行。

**但我要说清楚：这不是本轮有意的改动。** 最可能的原因是 GDScript 校验放宽后某个原本被拒绝的内容路径开始工作，从而消除了日历错位。我没有专门验证这个因果链，所以只能记录为「伴随改善，原因未证实」。

## 6. 验证

| 项 | 值 |
|---|---|
| 构建 | `scons: done building targets.`，exit 0 |
| GDScript 上限测试 | **19 checks, 0 failures** |
| C++ 纯核上限测试 | 35 checks, 0 failures |
| materializer / eligibility / shard / layer | 65 / 56 / 56 / 51，全 0 failures |
| 回归 | 回到基线 6 项非通过 |
| 新 DLL | `eb4e575b…` |

## 7. 局限

- **内容参数仍是 `(32, 0)`。** 校验已放宽，但 194 个 program 一个字都没动，所以有效目标集仍是 32 格。这是下一步。
- `runtime_ideology_parity_test` 的改善原因未证实（§5）。
- 未验证放宽后一个真正 `param[0] > 32` 的 program 能否端到端跑通——需要先有内容改动，而那会牵动 194 个文件。
- `selector_authored_cell_ceiling` 对有界种类仍返回 32；若将来某个径向种类确实需要更大上限，这里要单独放开而不是复用 32。

## 8. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_effect_definition_ceiling_test.gd'
# => 19 checks, 0 failures
```
