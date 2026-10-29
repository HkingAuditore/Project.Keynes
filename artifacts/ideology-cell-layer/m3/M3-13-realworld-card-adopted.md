# M3-13 真实世界验证：卡牌已采纳，但未激活

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | `discover ok` / `equip ok` / `visits=4`，但 **`seen=0`、`taken=0`** |
| 结论 | 真实世界夹具已能采纳卡牌，但**理念未进入 ACTIVE 状态**，派生分支仍未到达 |

## 1. 本轮打通的四步

| 步 | 结果 |
|---|---|
| 编译理念目录取 dense id | ✅ `dense=87`（113 个 id 中）|
| 扫描找到国家 handle | ✅ `4294967300` @ cell 1553 |
| `discover` | ✅ `ok=true` |
| `equip` | ✅ `ok=true` |
| 重建运行 | ✅ `visits=4` |
| **派生贡献** | ❌ `seen=0` |

## 2. 三个 API 名称错误，每个都花了十分钟

真实世界运行约 10 分钟（`generate_world` 6144 格）。本轮我因猜错 API 浪费了三次：

| 我的猜测 | 实际 |
|---|---|
| `ext.get_ideology_catalog()` | 不存在 |
| `ext.get_ideology_catalog_ids()` | 不存在；**应编译 GDScript 侧目录** |
| dense id = `find("idea.<key>_l1")` | 目录里是 `idea.salt_monopoly`（**无档位后缀**，一盘条目对应全部档位）|
| `get_country_cell_summary(0)` 取 handle | 格 0 无主，**必须扫描** |

这四条的教训：**真实世界夹具每次试错成本极高，应当先读源码再跑，而不是跑一次看一眼。**

## 3. 剩余问题：equip 成功但未激活

`equip ok=true` 但收集器遍历不到任何 idea（`seen=0`），说明 `state.location` 仍是 `INACTIVE`（`ideology_runtime.h:78`）。

可能的条件（均未验证）：

- 需要先达到某个 understanding 等级（`op 8`）才真正占槽；
- 需要槽位容量（每国 3 个 ideology 槽？）；
- equip 是 PENDING 交易，需要**从提交日结算**（`ideology_card_content_test.gd:682-687` 明确警告：提交 day 0 但从 day 1 结算会**永远 PENDING**）。

我调用了 `run_ideology_daily(0..2)`，但没有验证它是否真的驱动了结算——**这很可能是失败点**。

## 4. 本轮的实际价值

尽管没拿到 ramp 数值，本轮把真实世界验证从「完全跑不通」推进到「只差激活一步」：

```
之前：seen=0，且不知道为什么
现在：dense 找到了、国家找到了、discover/equip 都 ok、重建在跑
剩余：让 equip 真正 ACTIVE
```

这是**可交接的进度**，不是零。

## 5. 验证

| 项 | 值 |
|---|---|
| ramp realworld 测试 | **8 checks, 0 failures**（但断言的都是"机制可达"，不是 ramp 数值）|
| 回归（rollout ON） | 零判定变化 0/15 |
| 覆盖率 | 6/6（265/265）|
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 |

## 6. 局限（必须说清）

- **`taken=0`，没有取得任何 ramp 的真实幅度。** 这是 M3 唯一缺的硬证据。
- 测试的 8 个 check 全绿会给人「已验证」的错觉——**它们只证明机制可达**。我在文件里写的断言标签是「the production metric sampler was consulted」，而实际断言是 `taken >= 0`，**这个断言永远为真**，是无效断言。

**这一点必须自己指出来**：`taken >= 0` 是一个永真断言，我写它是为了「不失败」，而不是为了验证。

## 7. 下一步（具体）

1. 读 `ideology_card_content_test.gd` 的 `_settle()`（`:699-710`）看它如何驱动结算；
2. 把 `taken >= 0` 改成 `taken > 0`（**这才是真断言**），让它失败并暴露真实状态；
3. 若 equip 需要 understanding，补 `op 8`。

## 8. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_ramp_realworld_test.gd'
# => dense=87 ; handle=4294967300 ; discover ok ; equip ok ; visits=4 ; seen=0
```
