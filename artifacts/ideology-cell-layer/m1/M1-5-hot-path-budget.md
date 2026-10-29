# M1-5 hot path cost & budget — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §14.1 / §14.3 / §8.3 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `gdext/tests/derived_cell_layer_bench.cpp`、`gdext/tests/effective_value_increment_bench.cpp`、`Project/project-keynes/tools/ideology/m1_hot_path_budget.py` |
| 机器 | i9-13900K，O2 单线程，2026-10-27 |
| 结论 | 守卫有效（空层 +0.3 ns）；有层时每查询 +21.7…60.7 ns；**§14.1 的常量不是常量** |

## 1. 为什么要做两个基准

第一个基准（`derived_cell_layer_bench`）单独测两次二分，回答「查找多快」。
第二个（`effective_value_increment_bench`）同时测「legacy 三次哈希」与「legacy + 派生查找」，回答「M1 加了多少」。

**这两个问题不同。** 既有路径本来就要做三次 `unordered_map::find`（`modifier_runtime.cpp:1418-1425`），把那部分算成新增成本会高估回归。只有差值才是诚实的。

### 1.1 第一个基准抓出的第一个错：标签写错

首版有个用例叫 `"no layer, 2400 map"`，但它调的是 `build_front(2400, 1, 32)`——**建了一个 32 格的前**。名字说是「无层」，实际有层。

后果：这个用例显示 `delta_ns = 21.5`，看起来像「守卫也要 21 ns」。差一点把守卫判成无效。

修正后加了一个真正空的 front（`cells == 0`），并加注释说明为什么不能靠改名字蒙混。

### 1.2 空 front 崩溃

改成空 front 后程序直接 `0xC0000005` 崩溃——`front.rows.front()` 在空 vector 上越界。

这个崩溃本身有价值：**空 front 是一个合法的生产状态**（未装卡 / 迁移关闭），而基准代码默认它非空。生产路径用 `rows.empty()` 守卫着，所以没崩；基准自己漏了守卫。

## 2. 测量结果

### 2.1 增量成本（唯一诚实的「M1 加了什么」）

5 次重复取最小值（§14.4 记录的 ±15% 噪声下，最小值比均值稳定）：

| 场景 | legacy ns | combined ns | **delta ns** | delta× |
|---|---:|---:|---:|---:|
| **空层（守卫对照）** | 1.4 | 1.7 | **+0.3** | 1.22 |
| 单卡 32 格 | 4.3 | 26.1 | +21.7 | 6.04 |
| B7 1000 格 / 1 stat | 7.7 | 51.8 | +44.1 | 6.74 |
| 单国 6400 格 × 7 stat | 3.0 | 63.7 | +60.7 | 21.53 |

**守卫对照是这张表最重要的一行。** 空层时增量 0.3 ns ≈ 一次 bool 测试，与 §14.1 要求的「无层快速旁路」完全一致。若这一行显示几十 ns，说明守卫没生效，所有既有 reader 都会平白多付成本。

### 2.2 独立查找与集合枚举

| 场景 | 覆盖格 | lookup ns | **per-covered-cell us** | collect ms | front MB |
|---|---:|---:|---:|---:|---:|
| 单卡 32 格 | 32 | 20.4 | 3.2 | 0.001 | 0.0 |
| B7 1000 格 | 1,000 | 38.5 | 6.0 | 0.029 | 0.0 |
| 单国 6400 × 7 | 44,800 | 52.1 | 8.1 | 0.096 | 1.5 |
| 64 国 × 6400 × 7 | 2,867,200 | 119.6 | 18.7 | 8.705 | 98.4 |

`per-covered-cell = lookup_ns × 156 / 1000`。

## 3. 对方案 §14.1 的修正

§14.1（M0 修订后）写的是稳态 `covered_cells × 156`，隐含**常量固定**。

实测：这个常量本身从 **3.2 us 变到 18.7 us，跨 5.9 倍**。原因很直接——两次二分都随层规模变长（stat 数从 1 到 7，cell 数从 32 到 6400）。

**模型形式正确（线性于覆盖格数），但系数必须按部署规模分开给，不能写一个数。**

建议写法：

```
稳态冷建 ≈ covered_cells × 156 × c
   c = 3.2 us   （单卡规模，层很小）
   c = 6.0 us   （单国 1000 格）
   c = 8.1 us   （单国全国 6400 格 × 7 stat）
   c = 18.7 us  （64 国 × 6400 × 7，压力上界）
```

## 4. 与 §14.3 的「1 ms slice」门槛对照

B7（单国 1000 格）：`38.5 ns × 156 × 1000 = 6.01 ms`。

- 这是**整个 epoch 的 lookup 总成本**，不是单个 slice；
- 但 §14.3 要求「主线程单次派生 native slice ≤ 1 ms」，所以分片必须保证每片承担的格数 ≤ 约 166 格（`1 ms / 6.0 us`）；
- **M1 退出前必须确认分片粒度满足这一点**，否则会以「总成本可接受」掩盖单 slice 超标。

## 5. 内存

| 场景 | front MB |
|---|---:|
| 单国 6400 × 7 | 1.5 |
| 64 国 × 6400 × 7 | **98.4** |

§8.3 要求 front + candidate + retained **同时**计量。两份同时存在约 **197 MB**。

这是安装时预算检查（§17「内存预算不足 → 安装前显式失败」）必须用的数字。

## 6. 集合枚举的成本位置

64 国规模下：
- `collect_scope_ids`：**5.51 ms / 次**
- `collect_scope_stat_entries`：**8.71 ms / 次**

两者每个 epoch 各调用一次，因此在这个规模上可接受。但它们是 **O(派生行)**，正是 §8.5 说「不能为每次查询扫描全部」所禁止的形状。

**结论：目前安全，但它是一个待引爆的问题。** 任何未来新增的 per-cell 调用者都会立刻撞墙。per-stat CSR 是退路，M1 不需要，但必须记录在案。

## 7. 局限（必须与 §2 的数字一起引用）

- **O2 微基准，不是生产测量。** 它不模拟 cache miss，也不包含 `ModifierRuntime` 周围的真实状态。§14.4 要求的 in-situ 测量仍然欠着。
- **只测了单线程。** worker 路径的争用、false sharing 未测。
- **`collect_scope_*` 的基准是复刻实现，不是调用真实现。** 它独立重写了那个循环，所以若实现与基准漂移，数字会失真。真正的 in-situ 数字要等接线后。
- **未测 `install_derived_cell_layer` 本身的成本**（`content_digest` 是 O(行数)）。64 国规模下一次约 287 万行的哈希，可能达数十毫秒——**这项没测，是一个已知空白**。
- 未测峰值 RSS，只按结构体大小估算。

## 8. 复算方式

```powershell
cd gdext
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
cmd /c "call `"$vcvars`" >nul 2>&1 && cl /std:c++17 /O2 /EHsc /W4 /I src tests\effective_value_increment_bench.cpp /Fe:..\.codex-tmp\increment_bench.exe /Fo:..\.codex-tmp\"
& ..\.codex-tmp\increment_bench.exe

python Project/project-keynes/tools/ideology/m1_hot_path_budget.py
```
