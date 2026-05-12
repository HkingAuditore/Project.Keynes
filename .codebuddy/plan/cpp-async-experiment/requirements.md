## C++ 异步线程模型实验（D 方案）— 实验设计与契约

> 状态：设计完成，待实施
> 决策依据：见 `docs/cpp-gdscript-best-practices.md` §9 候选方案 D

---

### 0. 一句话目标

在不改动现有同步 pass 路径的前提下，给 `DCWorldExt` 加一组 **EXPERIMENTAL** async API，
让 GDScript 主线程可以"提交计算 → 立刻返回 → 下次 tick 看就绪"，
并测量 1 / N 个并发任务下的真实开销曲线。

---

### 1. 实验对象 & 不动的部分

- **实验对象**：复用 `run_demo_complex_pass` 的算法，把它包成"长期 worker 线程消费请求"的形式。
- **不动**：`run_temp_drift_pass` / `run_thermal_gradient_pass` / `run_climate_pass_a` /
  既有 bench / climate Pass-A 业务路径。
- **不引入**：第三方线程库；只用 `<thread>` `<mutex>` `<atomic>` `<condition_variable>`。

---

### 2. 通信架构

```
主线程 (Godot main)                  Worker 线程 (C++)
─────────────────────────────────────────────────────────
async_climate_register_task(task_id, n_workers=1)
     ↓ 创建 AsyncTask 实例 + 启 std::thread
                                     loop {
                                       wait_for(request_pending=true)
                                       memcpy 输入快照 → 私有 vector
                                       run_demo_complex_kernel(...)
                                       result_buf 切换 + atomic ready=true
                                       request_pending=false
                                     }

每帧主线程:
  async_climate_set_inputs(task_id, temp, elev)   ← memcpy 一次（~20 µs）
  async_climate_request(task_id, w, h, iter, ...) ← 设 pending + cv.notify
  ↓ 立即返回（<5 µs）
  ...其它逻辑...
  if async_climate_poll(task_id):                 ← 读 atomic（<1 µs）
      var snap = world_ext.snapshot_f32(CELL_DEMO_THERMAL_GRADIENT)
      // 此时 _slots[CELL_DEMO_THERMAL_GRADIENT].arr_f32 已被主线程内
      // poll() 调用从 worker 私有 result buffer memcpy 进来

async_climate_shutdown_task(task_id)
     ↓ 设 should_exit + cv.notify + join
```

**核心约束（不可违反）：**

1. Worker 线程内部**完全不调任何 Godot API**（Variant / push_warning / Object 一律禁止）。
2. Worker 线程内部**不持有 PackedFloat32Array 引用**——只用 `std::vector<float>` 私有 buffer。
3. 主线程在 `poll()` 返回 true 的瞬间，从 worker 私有 buffer **memcpy** 到 `_slots[].arr_f32.ptrw()`。
   GDScript 后续仍然走 `snapshot_f32()` 拿数据（接口不变）。
4. Worker 出错 → 写 `std::atomic<int> error_code`，主线程下一次 poll 看到后 push_warning。
5. `~DCWorldExt()` 必须可靠地停掉所有 worker（设 should_exit + notify + join），≤ 50 ms 完成。

---

### 3. C++ 数据结构

```cpp
struct AsyncTask {
    int task_id;
    std::thread worker;

    // 输入快照（主线程 set_inputs 时 memcpy 进来）
    std::vector<float> in_temp;
    std::vector<float> in_elev;

    // 双缓冲：worker 写 compute_buf，主线程在 poll() 时 memcpy 出 result_buf
    std::vector<float> compute_buf;
    std::vector<float> result_buf;

    // 请求参数（主线程写、worker 读，受 mtx 保护）
    int  grid_w = 0, grid_h = 0;
    int  iterations = 16, kernel_radius = 2;
    float coriolis = 0.5f, drag = 0.6f, gain = 1.5f, k = 0.5f;

    // 同步原语
    std::mutex mtx;
    std::condition_variable cv;
    std::atomic<bool> request_pending{false};
    std::atomic<bool> result_ready{false};
    std::atomic<bool> should_exit{false};

    // 计时（worker 写、主线程读）
    std::atomic<int64_t> last_worker_compute_us{0};
    std::atomic<int64_t> last_worker_total_us{0};
    std::atomic<int64_t> total_ticks{0};
    std::atomic<int64_t> total_reused{0};   // 主线程"复用旧结果"次数（worker 没赶上）
    std::atomic<int> error_code{0};
};

std::unordered_map<int, std::unique_ptr<AsyncTask>> _async_tasks;
std::mutex _async_tasks_mtx;
```

---

### 4. 新增公开 API（GDScript-facing）

```cpp
// 注册任务（启 worker）
void async_climate_register_task(int task_id, int n_workers /*暂仅 1*/);

// 提交输入快照（主线程内做 memcpy；调用前应保证 in_temp / in_elev 大小 = grid_w*grid_h）
void async_climate_set_inputs(int task_id,
                              const PackedFloat32Array &temp,
                              const PackedFloat32Array &elev);

// 提交一次计算请求（主线程立即返回；worker 异步消费）
void async_climate_request(int task_id,
                           int grid_w, int grid_h,
                           int iterations, int kernel_radius,
                           float coriolis, float drag,
                           float elevation_gain, float normalize_k);

// 拉取就绪结果：返回 true 表示有新数据；同时把 compute_buf memcpy 进 _slots
// 输出 slot 名仍是 "cell_demo_thermal_gradient"（与同步 pass 一致，便于复用 overlay）
bool async_climate_poll(int task_id);

// 主线程读耗时统计（µs）
Dictionary async_climate_stats(int task_id);
//   { worker_compute_us, worker_total_us, total_ticks, total_reused, error_code }

// 注销任务（join worker）
void async_climate_shutdown_task(int task_id);

// 全局 shutdown（析构函数会自动调用）
void async_climate_shutdown_all();
```

---

### 5. 5+2 维度成功判据

| # | 判据 | 目标 |
|---|------|------|
| 1 | 主线程 `set_inputs+request+poll` 总耗时 | ≤ 50 µs / tick |
| 2 | 异步 vs 同步逻辑等价（同输入 → 同输出，容差 1e-6） | PASS |
| 3 | worker 卡顿（人为 sleep 30 ms）时主线程不阻塞 + 复用旧 buffer | PASS |
| 4 | 100 次 register/shutdown 循环不 crash / 不死锁 | PASS |
| 5 | bit-equal vs GDScript reference（容差 1e-6） | PASS |
| 6 | **耗时全景**：5 项指标分别记录（main_dispatch / main_poll / worker_compute / worker_total / latency_frames） | 全部出表 |
| 7 | **并发开销曲线**：N=1/2/4/8 并发任务 worker_total 是否接近 N=1 baseline | 出图表 |

---

### 6. bench 矩阵（自动化）

新文件 `Project/project-keynes/tmp/bench_async_demo_complex.gd`：

| Case | N tasks | grid | iter | 关注 |
|-----|---------|-----|-----|------|
| C1  | 1 | 60×40 | 16 | baseline |
| C2  | 1 | 60×40 | 64 | 单任务高负载（探索 worker 极限） |
| C3  | 2 | 60×40 | 16 | 2 任务并行，看 contention |
| C4  | 4 | 60×40 | 16 | 4 任务并行，看物理核 saturation |
| C5  | 8 | 60×40 | 16 | 8 任务并行，看主线程 dispatch budget |
| EQ  | 1 | 32×32 | 4 | 异步 vs 同步等价性（bit-precise，容差 1e-6） |
| ROBUST | — | — | — | 100 次 register/shutdown 循环 |

每个 perf case 跑 30 warmup + 100 measure tick，输出：
- main_dispatch_us 平均
- main_poll_us 平均
- worker_compute_us 平均
- worker_total_us 平均
- latency_frames 分布（期望 ≈ 1.0）
- total_reused 次数（worker 跟不上的帧数）

---

### 7. 范围之外（不做）

- ❌ 共享 worker 池（多任务串行同一 worker）—— 这次只做"每任务独享 worker"
- ❌ SIMD / 算法优化
- ❌ climate Pass-A 真实业务接入
- ❌ DataOverlay 显示挂接（同步 demo 已经能看，异步不重复）

---

### 8. 产出清单

1. 代码：
   - `gdext/src/world_ext.h/.cpp` 新增 async API（带 `// EXPERIMENTAL` 标记）
   - `_bind_methods` 注册新方法
2. bench：
   - `tmp/bench_async_demo_complex.gd`（自动化 7 维度）
3. 文档：
   - `docs/cpp-async-experiment-report.md`（实验报告 + 7 条判据通过情况 + 并发曲线 + 推荐结论）
   - 更新 `docs/cpp-gdscript-best-practices.md` §9，把 D 方案的真实数据填进去

---

### 9. 风险与回滚

- 实验代码全部走新 API，不与现有 pass 共享路径 → 失败可直接删 async_* 系列方法。
- 析构鲁棒性是本次最大风险点，先写自动化测试 ROBUST，再上其它 case。

