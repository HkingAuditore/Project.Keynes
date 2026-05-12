
# Project Keynes — C++/GDScript 协作最佳实践（面向新手）

> 文档定位：你是第一次接触本项目 GDExtension（C++）通路、想搞清楚"什么时候该用 C++、怎么用、怎么不踩坑"的人。读完这份文档之后，你应该能自己开一个新的 C++ pass、跑通 bench、把结果叠到地图上，全程不需要别人陪同。
>
> 本文档是**操作手册**。它的事实数字和性能基线来自 [`docs/performance-charter.md`](./performance-charter.md) §12 系列章节——后者是**契约/规范**。两份文件配合阅读：charter 回答"我们承诺什么"，本文档回答"我具体怎么做"。

---

## 0. 你需要先理解的三句话

1. **GDScript 写"游戏逻辑"，C++ 写"逐格子的密集计算"。** 不要反过来。
2. **数据的"主"在 C++ 端**（`DCWorldExt._slots[].arr_f32`），GDScript 通过 `snapshot_f32(comp_id)` 拉一份**只读快照**来用。GDScript 改快照不会反向写回 C++——这是**故意的**。
3. **C++ pass 是纯函数：** 输入参数 + `_slots` 状态 → 修改 `_slots` 状态。不读 Godot 节点、不调 Godot API、不持有任何场景引用。

如果上面三句话有一句你觉得"为什么必须这样"，请读完 §3。不要绕过它。

---

## 1. 全局架构地图（一张图记住）

```
┌──────────────────────── GDScript 层（res://scripts/...）─────────────────────┐
│                                                                              │
│    main.gd  ──tick──►  DCWorld  ──delegates──►  DCWorldExt  (RefCounted, C++)│
│       │                                              │                       │
│       │ snapshot_f32(comp_id)                        │                       │
│       │  ⇣ 只读 PackedFloat32Array（CoW 拷贝）       │                       │
│       │                                              │                       │
│       └─► DataOverlayBaker ─► DataOverlayLayer ─► 屏幕上的彩色格子             │
│                                                      │                       │
└──────────────────────────────────────────────────────┼───────────────────────┘
                                                       │
                                                       ▼
┌─────────── C++ 层（gdext/src/world_ext.cpp）—— "数据的主" ────────────────────┐
│                                                                              │
│    _slots[CELL_TEMP].arr_f32                ← cell_temp（输入）              │
│    _slots[CELL_ELEVATION].arr_f32           ← cell_elevation（输入）         │
│    _slots[CELL_DEMO_THERMAL_GRADIENT].arr_f32  ← demo 输出（pass 写入）      │
│                                                                              │
│    run_thermal_gradient_pass(...)  ← 你新写的 pass 长这样                    │
│    run_demo_complex_pass(...)      ← 复杂版本                                │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

**记忆要点：**
- 所有 `_slots[].arr_f32` 这样的 SoA 大数组，**只在 C++ 端真实存在**。GDScript 看到的都是快照副本。
- GDScript 调一次 C++ 函数（比如 `world_ext.run_thermal_gradient_pass(60, 40, 1.5, 0.5)`）就发生**一次跨语言边界过桥**。过桥本身有几微秒固定开销，所以**永远不要在 GDScript 里 for 循环按格子调 C++ 函数**——要传整个 `PackedFloat32Array` 一次过。

---

## 2. 通信链路实测（你将得到的速度）

| 配置（`60×40 cell`，`iter=16, kr=2`） | C++ 端耗时 | GDScript 端耗时 | 加速比 |
|--------------------------------------|-----------|-----------------|--------|
| Pass #1 简单算子（`temp_drift`）     | ~22 µs    | ~222 µs         | ~10×   |
| Pass #2 邻居算子（`thermal_gradient`） | ~15 µs    | ~354 µs         | ~24×   |
| Pass #3 迭代+三角函数（`demo_complex`） | ~1042 µs  | ~150 000 µs     | ~140×  |

> 数据出处：[`docs/performance-charter.md`](./performance-charter.md) §12.6.6.b。

**经验定律：** 算子越复杂，C++ 优势越大。简单算子 10 倍、复杂算子 100+ 倍。

**反之的告诫：** 极简单的算子（"对每个格子加一个常数"）走 C++ 也只有 10 倍收益，**但你要付出"跨语言桥 + bench 验证 + bit-equal 复刻"的工程成本**。这种小算子直接在 GDScript 写就行，**不要为了"用 C++"而用 C++**。

---

## 3. 数据所有权与生命周期（明文契约）⚠️ 重点章节

这是新手最容易踩的坑，也是 2026-05-12 climate Pass-A "全蓝 bug" 的根因。请逐字读完。

### 3.1 历史背景：我们曾经走错过

最初的设计叫 **"zero-acceleration alias"**（零加速别名）：
- GDScript 的 `MapData.temp_arr` 和 C++ 的 `_slots[CELL_TEMP].arr_f32` 试图**指向同一块内存**（COW 别名）。
- 想法是：C++ 改了 `arr_f32`，GDScript 那边读 `MapData.temp_arr` **自动**就能看到新值。

这套契约**在两个 pass 之间被静默破坏了**。Godot 的 PackedArray 是写时复制（CoW）：只要任何一方做了一次普通赋值，别名就断开，从此各写各的，**且不会报错**。我们在 climate Pass-A 上看到了"全蓝 bug"——pass 算了，但 GDScript 端拿到的永远是初始值。

### 3.2 现在的契约：Mode-B（Owned-by-C++）

**单一所有权：** 大数组的"主"是 C++ 端的 `_slots[].arr_f32`。**GDScript 不持有真正的数据。**

**读取协议：**
```gdscript
# GDScript 想读 C++ 端最新数值时，**永远走 snapshot**：
var temp_snapshot: PackedFloat32Array = world_ext.snapshot_f32(CELL_TEMP)
# temp_snapshot 是一份**值拷贝**（CoW），随便改它都不会影响 C++ 端。
# 你不需要关心它什么时候释放——Godot 的引用计数管。
```

**写入协议（GDScript → C++）：**
```gdscript
# 单格写：
world_ext.write_f32(CELL_TEMP, idx, 0.42)

# 一段连续区间写：
world_ext.write_f32_range(CELL_TEMP, start_idx, src_array)

# 稀疏写（dirty 列表）：
world_ext.write_f32_indexed(CELL_TEMP, indices_array, values_array)
```
**永远不要这样做：**
```gdscript
# ❌ 错误：以为这能写回 C++
var arr = world_ext.snapshot_f32(CELL_TEMP)
arr[100] = 0.42   # 这只改了你手上的副本，C++ 端毫无变化
```

**hot pass 协议（C++ 内部）：**
```cpp
// ✅ 正确：直接对 _slots[].arr_f32 操作，永远不要 obj.set() 推回 GDScript
float * const __restrict p = s.arr_f32.ptrw();
for (int i = 0; i < n; ++i) {
    p[i] += drift_amount;
}
// 不要在末尾加 map_data->set("temp_arr", s.arr_f32) —— Mode-B 不依赖推回。
```

### 3.3 生命周期一图流

```
T=0  GDScript 启动 → 实例化 DCWorldExt
                  → world_ext.register_component("cell_temp", F32, ...)
                  → C++ 端 _slots[CELL_TEMP].arr_f32 被分配为 size = n_cells
                                              （从此**它是数据的唯一权威**）

T=任意 tick      GDScript: world_ext.run_thermal_gradient_pass(60, 40, 1.5, 0.5)
                  → C++ 跨语言边界 → ptrw() 直接改 _slots[].arr_f32
                  → 函数返回，arr_f32 已被原地更新

T=任意 tick      GDScript 想看结果：
                  → var snap = world_ext.snapshot_f32(CELL_DEMO_THERMAL_GRADIENT)
                  → 拿到一份 CoW 副本，喂给 baker 上色

T=Godot 退出    DCWorldExt 引用归零 → ~DCWorldExt() → _slots 析构 → arr_f32 释放
```

**关键结论：你不需要手动释放任何东西。** C++ 端的 `_slots` 跟着 `DCWorldExt` 的生命周期，GDScript 端的 PackedArray 跟着引用计数。但你**必须遵守"读快照 / 写专用 API"的协议**——一旦你试图绕过它（比如直接修改 snapshot 拿到的数组并希望反向写回），你就会重蹈 climate Pass-A 的覆辙。

### 3.4 一句话备忘

> **C++ 是数据的主，GDScript 是数据的访客。访客可以拿一份纪念品（snapshot），但不能改主人家的家具——要改，请通过专门的施工队（`write_*` 接口）下单。**

---

## 4. 从零开始：开一个新 C++ pass（手把手 step-by-step）

我们以"在 cell_temp 上每格 +drift_amount"这个最简单的 pass 为例。**这就是 `run_temp_drift_pass` 的真实代码**——你日后写新 pass，**先复制粘贴这个模板**再改。

### Step 1：在 `gdext/src/world_ext.h` 中声明

```cpp
// 在 public: 区域加：
void run_temp_drift_pass(float drift_amount);
```

### Step 2：在 `gdext/src/world_ext.cpp` 中实现

```cpp
void DCWorldExt::run_temp_drift_pass(float drift_amount) {
    // ─── 1. 解析 slot id（一次，不在 loop 里）─────────────────────
    const int sid = component_id(StringName("cell_temp"));
    if (sid < 0) {
        return;  // slot 没注册 → 安全无操作（不要 crash）
    }
    Slot &s = _slots.write[sid];
    if (s.dtype != SlotDType::F32) {
        return;  // 类型不匹配 → 安全无操作
    }
    const int n = s.arr_f32.size();
    if (n <= 0) {
        return;
    }

    // ─── 2. 拿一次 ptrw()，进入热循环 ─────────────────────────
    float * const __restrict p = s.arr_f32.ptrw();
    for (int i = 0; i < n; ++i) {
        p[i] += drift_amount;
    }

    // ─── 3. 不要 obj.set() 推回 GDScript ──────────────────────
    // Mode-B 协议：GDScript 用 snapshot_f32 拉，不要推回。
}
```

### Step 3：在 `_bind_methods` 注册（让 GDScript 能调）

打开 `world_ext.cpp` 找到 `void DCWorldExt::_bind_methods()`，加一行：

```cpp
ClassDB::bind_method(
    D_METHOD("run_temp_drift_pass", "drift_amount"),
    &DCWorldExt::run_temp_drift_pass);
```

**字符串 "run_temp_drift_pass" 必须和 GDScript 里的调用名完全一致**。`"drift_amount"` 是参数名（在编辑器自动补全里会看到）。

### Step 4：编译 GDExtension

```bash
cd gdext
scons platform=windows target=template_debug
```
编译完成后，Godot 编辑器**不需要**重启，但**正在运行的游戏需要重启**才能加载新 .dll。

### Step 5：从 GDScript 调用

```gdscript
# 在某个 tick 里：
world_ext.run_temp_drift_pass(0.5)

# 想看结果：
var snap = world_ext.snapshot_f32(world_ext.component_id("cell_temp"))
print("first cell after drift: ", snap[0])
```

### Step 6：写 GDScript 参考实现（必须！）

在 `Project/project-keynes/tmp/` 下新建 `bench_temp_drift.gd`，把同样的算法用 GDScript 写一遍：

```gdscript
# GDScript 参考实现（reference impl）
static func temp_drift_reference(temp_arr: PackedFloat32Array, drift_amount: float) -> PackedFloat32Array:
    var out = temp_arr.duplicate()
    var n = out.size()
    for i in range(n):
        out[i] += drift_amount
    return out
```

### Step 7：双跑 + bit-equal 校验

```gdscript
# bench 主逻辑：
var input := _make_test_input(1024)

# C++ 路径
world_ext.bind_test_array(input)  # 通过 write_f32_range 灌进去
var t0 = Time.get_ticks_usec()
world_ext.run_temp_drift_pass(0.5)
var cpp_us = Time.get_ticks_usec() - t0
var cpp_out = world_ext.snapshot_f32(comp_id)

# GDScript 参考路径
var t1 = Time.get_ticks_usec()
var gd_out = temp_drift_reference(input, 0.5)
var gd_us = Time.get_ticks_usec() - t1

# bit-equal 校验
var diverge = 0
for i in range(cpp_out.size()):
    if cpp_out[i] != gd_out[i]:
        diverge += 1
print("C++ %d µs | GDScript %d µs | diverge %d" % [cpp_us, gd_us, diverge])
assert(diverge == 0, "bit-equal FAILED")
```

**这一步是绝对不能省的。** 你**永远**应该有一份 GDScript reference impl 跟你的 C++ 算法对齐——它是你算法对错的唯一可信审计源。即使 C++ 跑得飞快，没有 reference 你不知道它对没对。

### Step 8：bit-equal 政策（重要）

| 算子复杂度 | bit-equal 期望 | 容差 |
|-----------|--------------|------|
| 仅加减乘 / 整数运算 | **严格 bit-equal**（0 偏差） | tolerance = 0 |
| 含 `sqrt / clamp` | bit-equal（精度由 IEEE-754 保证） | tolerance = 0 |
| 含 `sin / cos / 高斯权重 / 多 iter 累加` | **软等价** | tolerance ≤ 1e-6 |

> 出处：参见 charter §12.6.6。Pass #2 是严格 bit-equal，Pass #3 是软等价（max_diff ≈ 6e-8）。

如果你的 pass 含浮点超越函数（sin/cos/exp/log），**先就把 tolerance 设为 1e-6**，不要追查个位 ULP 差异——那是浮点 IEEE 在不同编译器/平台上不同的舍入策略，不是 bug。

### Step 9：（可选）挂到 DataOverlay 预览

如果你想在 main.tscn 里**用颜色看到**这个数据：

1. 在 `DCWorld` 注册一个新 component，比如 `cell_demo_drift`，dtype=F32。
2. 在你的 pass 里把结果写到这个 slot。
3. 在 `DataOverlayBaker` 的 enum 里加一个新模式，`snapshot_f32(CELL_DEMO_DRIFT)` 取值，喂给 layer。

模板代码参考现有 `cell_demo_thermal_gradient` 在 `main.gd` 里的接入方式（见 `DataOverlayBaker._bake_thermal_gradient_mode`）。

---

## 5. 写 hot loop 的"军规"（违反必踩坑）

这一节是 charter §12.6 已经写过的话，但新手必须**逐条**读完一次。

| # | 规则 | 反例（错） | 正例（对） |
|---|------|----------|----------|
| 1 | 解析 slot id**只在循环外**做一次 | `loop { component_id(StringName("..."))[i] }` | `int sid = component_id(...); loop { use sid }` |
| 2 | `ptr()` / `ptrw()` 一次拿到，用裸指针迭代 | `loop { arr.ptrw()[i] = ... }` | `auto p = arr.ptrw(); loop { p[i] = ... }` |
| 3 | 内层循环**零 Variant 操作** | `loop { Dictionary d = obj->get(...) }` | 提前一次性把要用的标量参数拷到栈变量 |
| 4 | 邻居访问用整数索引，不要 modulo wrap | `int west = (i - 1 + n) % n;` | `int west = (x > 0) ? (i - 1) : i;`（clamp-to-edge） |
| 5 | 中间运算**用 double**，存回时再 narrow 到 float | `float gx = ...; float out = sqrt(gx*gx+gy*gy)*amp*k;` | `double gx = ...; OUT[i] = (float)(sqrt(gx*gx+gy*gy)*amp*k);` |
| 6 | 多个 buffer 迭代用 ping-pong，不要原地读写自己 | `for it { buf[i] = f(buf[i-1], buf[i+1]) }` | `for it { dst[i] = f(src[...]) ; swap(src,dst) }` |
| 7 | 出错 → `push_warning` + `return`，**不要 crash** | `assert(sid >= 0)` 直接挂掉 | `if (sid < 0) { push_warning(...); return; }` |

**关于第 5 条 "double 中间值"：** 这条是 bit-equal 校验通过的关键。GDScript 的 PackedFloat32Array 在内存上是 32-bit float，但**算术运算时 GDScript 会自动 promote 到 64-bit**，所以 GDScript 的 reference impl 里所有中间运算都是 double。你 C++ 这边也必须一致地用 double 做中间运算，最后一刻才 narrow 回 float 存储——不然你会得到 ~1e-6 的偏差，bit-equal 失败。

---

## 6. bench 文件与 demo 文件的区别（不要搞混）

| 文件类型 | 路径 | 用途 | 上线状态 |
|---------|------|------|---------|
| **bench**  | `Project/.../tmp/bench_*.gd`  | 双跑 + bit-equal + 性能表，**只在 dev 跑** | tmp 目录不打包 |
| **demo**   | `Project/.../tmp/demo_*.gd` 或挂在 main 场景下的开关 | 真实 tick 里调 C++ pass、把结果上色到 overlay 看效果 | dev 用，正式版本通过开关关掉 |
| **production pass** | `gdext/src/world_ext.cpp` 里 `run_xxx_pass` | 真正给 climate / 经济使用的算子 | release 走这个 |

**bench / demo 的代码不要进 release。** main 场景里所有 demo 的开关都要默认 false。

---

## 7. 何时**不**该把代码搬到 C++

新手常犯的错是"看到 C++ 快就什么都往里搬"。下面这些情况**继续用 GDScript** 反而更对：

| 情况 | 为什么 |
|-----|------|
| 一帧调用次数 < 10 次 | 跨语言桥本身有几微秒开销，10 次以内 GDScript 完全够用 |
| 算子涉及大量 Godot 节点查询 / 信号 | C++ 里调 Godot API 还是要过桥，得不偿失 |
| 算法还在调参、每天改 5 次 | GDScript 改一行就能跑，C++ 每改一次都要 scons 编译 |
| 数据规模 < 100 元素 | 这个量级 GDScript 的 PackedArray 也是 cache-friendly 的 |
| UI / 交互逻辑 | GDScript 的信号/await/coroutine 远比 C++ 写起来短 |

**判断 checklist：** 一个候选函数要不要 C++ 化，先问自己：
1. 它会被 tick 调用 ≥ 1 次/帧吗？
2. 它每次处理的数据量 ≥ 千级元素吗？
3. 它在 profiler 里占总帧时 ≥ 5% 吗？

**三条都 yes 才考虑** C++ 化，否则别动。

---

## 8. 调试与排查（出问题时按这个顺序查）

### 症状 1：C++ pass 跑了但数据没变 / 全是初始值
- 是不是写完忘了 scons 编译？
- 是不是 game.exe 没重启？
- 是不是 component 没注册（`component_id` 返回 -1）？检查 `push_warning` 输出。
- 是不是误用了"修改 snapshot 副本希望写回"的反模式？复读 §3。

### 症状 2：bit-equal 失败
- 中间运算是不是没用 double？复读 §5 第 5 条。
- 边界处理是不是不一致（C++ 用 clamp，GDScript 用 wrap）？
- 浮点超越函数（sin/cos）容差设了吗？应 ≥ 1e-6。

### 症状 3：编译过了，运行时 Godot 崩溃
- 99% 是 ptrw() 拿到指针后越界写。检查所有 `[i]` 是否 `i ∈ [0, n)`。
- 检查 `slot.arr_f32.size()` 在拿 ptrw 之前是否做过 size 校验。

### 症状 4：性能没达到预期
- 你是不是在 GDScript 里 for 循环按格子调 C++？合并成一次批量调用。
- 你是不是没 `__restrict` ？这能让编译器自动向量化。
- 用 charter §12.6.6.b 的"经验定律"重新估时长。

---

## 9. 进阶：何时考虑线程化（D 方案已实测，可量产）

**目前所有 *production* C++ pass 都是主线程同步阻塞的。** `run_demo_complex_pass` 在 60×40/iter=64/kr=5 时实测 ~10 ms 单次——这 10 ms 是把 Godot 主线程**完全卡住**的 10 ms。

如果你要做的真实 climate pass 累计起来超过 4 ms / 帧（@60 FPS 的安全预算），就到了必须考虑线程化的时候。本项目已经完成了 D 方案的可行性实验，**结论是：D 方案完全可量产**。详细数据见 [`docs/cpp-async-experiment-report.md`](./cpp-async-experiment-report.md)。

### 9.1 D 方案速览

> "长期 worker 线程 + 双缓冲" — 主线程提交请求立刻返回，worker 后台算，下次 tick 主线程 poll 拿结果。

代码入口（`gdext/src/world_ext.h` EXPERIMENTAL 区块）：
```cpp
async_climate_register_task(task_id, n_workers)   // 启 worker
async_climate_set_inputs(task_id, temp, elev)     // memcpy 输入快照
async_climate_request(task_id, w, h, iter, kr,    // 提交请求（立即返回）
                      coriolis, drag, gain, k)
async_climate_poll(task_id) -> bool               // 拉取就绪结果
async_climate_stats(task_id) -> Dictionary        // 5 维度耗时
async_climate_shutdown_task(task_id)              // join worker
```

### 9.2 实测性能（这台开发机，60×40/iter=16）

| 配置 | 主线程 dispatch+poll | 后台 worker_compute | 主线程开销结论 |
|------|---------------------|---------------------|---------------|
| **同步 sync(ref)** | n/a（主线程被卡 833 µs） | 833 µs | 同步路径主线程独吞 |
| **D 方案 N=1** | **12 µs** | 971 µs | 主线程腾出 821 µs 干别的 |
| **D 方案 N=4** | **30 µs** | 1194 µs / worker | 4 个并发任务，主线程仅占 30 µs |
| **D 方案 N=8** | **56 µs** | 1705 µs / worker | 8 并发已触及 CPU 核饱和 |

- 异步 vs 同步：**bit-equal max_abs_diff = 0.0**（无任何浮点偏差）
- 100 次 register/shutdown 循环：**平均 180 µs/cycle，零 crash 零死锁**

### 9.3 何时该选 D 方案 vs 同步

| 场景 | 推荐方案 | 理由 |
|-----|---------|------|
| 单次 ≥ 200 µs 的 hot pass | **D 方案** | 收益 ≥ 188 µs/帧主线程预算 |
| 单次 < 50 µs 的小算子 | 同步 | 跨线程 ~12 µs dispatch + memcpy 输入 ≈ 计算本身，无意义 |
| 每帧 ≤ 4 个并发后台任务 | **D 方案** | 主线程 30 µs；worker 增长 < 50% |
| 每帧 ≥ 8 个并发任务 | **暂缓**，先做共享 worker 池 | 物理核饱和 → worker_compute 翻倍 |
| 本帧必须算出 + 本帧消费 | 同步 | D 方案是"下一帧拿"，不适合反馈环 |

### 9.4 D 方案的"红线契约"（违反必踩坑）

> 这条契约是 D 方案能正确工作的根基，任何修改 `world_ext.cpp` async 路径的人**必须逐字遵守**：

1. **Worker 线程内绝对不调任何 Godot API。** 不要 `Variant`、不要 `push_warning`、不要 `Object::get/set`。Worker 只读写 `std::vector<float>` 和 atomics。错误用 `std::atomic<int> error_code` 上报，主线程 poll 时翻译成 `push_warning`。
2. **输入要在 `set_inputs` 时 memcpy 进 `std::vector`。** 不要直接持有 `PackedFloat32Array` 的引用——它的 CoW 引用计数不是线程安全的。
3. **输出在 `poll()` 内 memcpy 回 `_slots[].arr_f32`。** Worker 只写自己的私有 `result_buf`；主线程在 poll 真返回 true 时才碰 `_slots`。
4. **`~DCWorldExt()` 必须调 `shutdown_all()` 兜底。** 否则 worker 线程会被悬空析构。

### 9.5 现状：production 路径还是同步

虽然 D 方案已验证可量产，但**当前所有真实 climate pass（包括 climate Pass-A）仍然走同步路径**——切换是一个独立的小项目，需要：

1. 把 `run_climate_pass_a` 的算法抽出成纯 C++ kernel（已经基本是了）
2. 加 `async_climate_pass_a_*` 系列 API（仿照 `async_climate_*` 模板）
3. 改 `main.gd` 的 climate tick 路径：dispatch → 下帧 poll
4. 跑 `bench_async_climate_pass_a.gd` 验证 bit-equal + 性能

**新手不要自己上手做 D 方案接入——先和团队同步。** 但如果你只是想了解"为什么这套东西能 work"，把上面的实验报告读一遍就够了。

> 备选方案 B（保持同步 + ≤ 4 ms × ≤ 4 pass / 帧守门）和方案 C（tick 切片）目前**不再优先**，因为 D 方案数据已经足够好。


---

## 10. 速查表：5 分钟回忆

| 我想做什么 | 我应该去看 | 我应该改 |
|-----------|----------|---------|
| 开一个新 C++ pass | 本文 §4 | `world_ext.h/.cpp`，加一个 `run_xxx_pass` |
| 让 GDScript 能调它 | 本文 §4 Step 3 | `_bind_methods()` |
| 让 GDScript 看到 C++ 算的数据 | 本文 §3.2 | 用 `snapshot_f32(comp_id)` |
| 让 GDScript 写数据进 C++ | 本文 §3.2 | 用 `write_f32 / write_f32_range / write_f32_indexed` |
| 估算我的 pass 会跑多久 | charter §12.6.6.b 的表 + 经验定律 | — |
| 把数据可视化叠到地图上 | 本文 §4 Step 9 | `DataOverlayBaker` 加一个新模式 |
| 验证 C++ 算对了 | 本文 §4 Step 6-8 | 写一份 GDScript reference impl + bench |
| 看通信契约的"为什么这样" | 本文 §3 + charter §12 | — |

---

## 11. 进阶储备：ECS 调度模型（仅作为 future-proof 索引）

> 这一节**不属于**新手流程。只是给"未来 pass 数量增长后"的接手者一个指针。
> 当前 production 仍然手写 tick 顺序在 `main.gd`，**不要**为了用 ECS 而用 ECS。

如果将来 pass 数量超过 ~10 个、互相依赖复杂到手写 tick 顺序难以维护，可以参考
[`docs/dots-experiment-report.md`](./dots-experiment-report.md) 的 A2 实验—— 我们已
经在 GDScript 沙盒里验证了"声明式 reads/writes + Kahn 拓扑排序"的可行性
（bit-equal = 0.0、环检测正常）。届时**直接立项 ECS 设计文档**即可，不必从零探索。

**调度器开销契约（实测）**：在真实 C++ pass 流水线（drift / thermal_gradient /
demo_complex 混搭，J ∈ {3, 5, 8}）下，scheduler 净开销在 J=8 时 **+5.08%**，
远低于 25% 红线，bit-equal 全 PASS（见 dots-experiment-report.md §3.6）。这意味着
**接入 ECS 调度器的代价是工程层面的（多一层间接、要写依赖声明），而非性能层面的**——
不要因为"怕慢"而抵触它。

> **同样重要的是反向告诫**：在 **单 pass / 单 job 场景**下 ECS 调度器是**纯开销 0
> 收益**——`bench_thermal_gradient_paths.gd` 实测 LEGACY ≡ ECS 但 ECS 多花
> 13-20 µs。所以 demo `cell_demo_thermal_gradient` 的 production 默认路径已改回
> `LEGACY`（见 `climate_profile.gd` `DemoTGPath`）。**ECS / ECS_ARCHETYPE 仅作为
> 切换选项保留**，便于回归对照。这条经验适用于所有候选 pass：**只有 ≥ 2 条 job
> 之间有真实依赖时才考虑 ECS**。

同份报告的 A1 实验也给出了一个**重要的负面结论**：archetype 作为"逻辑过滤器"
在 stencil 类算子上无性能收益（cache miss 抵消跳过的算力）。这意味着真要拿到
archetype 加速必须做 SoA chunk 物理重排，而后者是**项目级重构**，目前没有压力
证明值得做——读完报告 §2.4 / §4 选项丙就能明白为什么。

**简而言之：当前继续按 §1-§10 写 C++ pass 即可，A1/A2 是储备不是流程。**

---

## 12. 维护者笔记

- 本文档面向**新手**。如果你是老手，需要查具体的事实数字、实测表、bench 复现命令——直接去 `docs/performance-charter.md` §12.6 系列章节，那里更准确。
- 本文档**不**展开 ECS / archetype / 真 DOTS 数据布局的讨论。相关实验沉淀在
  [`docs/dots-experiment-report.md`](./dots-experiment-report.md)，本文 §11 仅给一个轻量级指针。
- 当 §3 的契约（Mode-B）发生变更时，**必须同步更新本文档**——不然新手会按旧契约写出 bug。

---

_最后更新：2026-05-12_
_对应代码版本：commit 包含 `run_demo_complex_pass` 与 `snapshot_f32` 接口的版本_
