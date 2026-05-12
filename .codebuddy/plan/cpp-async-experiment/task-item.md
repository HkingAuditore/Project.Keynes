## C++ 异步线程模型实验 — 任务清单

> 每条勾选完打 `[x]`；执行顺序严格自上而下（后项可能依赖前项的 API）。
>
> **状态：全部完成 ✅（2026-05-12）**
> **实验报告：** `docs/cpp-async-experiment-report.md`

### Phase 1：C++ async 基础设施

- [x] T1.1 在 `world_ext.h` 中新增 `// === EXPERIMENTAL: D-async ===` 区块，
       声明 `AsyncTask` 内部结构（前置声明放头文件，定义放 cpp 匿名命名空间）。
- [x] T1.2 在 `world_ext.h` 声明 7 个公开方法：
       `async_climate_register_task / set_inputs / request / poll / stats /
       shutdown_task / shutdown_all`.
- [x] T1.3 在 `world_ext.cpp` 包含 `<thread>` `<mutex>` `<condition_variable>` `<atomic>`
       `<chrono>` `<vector>` `<unordered_map>`；声明匿名命名空间内的
       `AsyncTask` 完整结构 + worker 主循环静态函数 `_async_worker_main`.

### Phase 2：worker 线程实现

- [x] T2.1 实现 `_async_worker_main(AsyncTask*)`：
       loop → cv.wait(pending || should_exit) → memcpy 输入 → 执行
       demo_complex 算法（**纯 std::vector，零 Godot API**）→ 设 result_ready.
- [x] T2.2 抽出 `_demo_complex_kernel_pure_cpp(...)`：
       从 `run_demo_complex_pass` 的算法主体拷贝（步骤 3-8）改成"输入 in_temp/in_elev、
       输出 out_buf 都是 `std::vector<float>`"的纯 C++ 版本。算法 100% 一致以保证 bit-equal.

### Phase 3：主线程公开 API 实现

- [x] T3.1 `async_climate_register_task(task_id, n_workers)`：创建 AsyncTask、
       resize 内部 vector、`std::thread` 启动 worker.
- [x] T3.2 `async_climate_set_inputs`：memcpy `PackedFloat32Array` →
       `std::vector<float>`（带 mutex 保护）.
- [x] T3.3 `async_climate_request`：mutex 下设参数 → atomic pending=true → cv.notify.
- [x] T3.4 `async_climate_poll`：检查 atomic ready → 若 true，
       memcpy result_buf 到 `_slots[CELL_DEMO_THERMAL_GRADIENT].arr_f32.ptrw()`，
       返回 true；否则返回 false 并累加 total_reused.
- [x] T3.5 `async_climate_stats`：把 atomic 计数打包成 Dictionary 返回.
- [x] T3.6 `async_climate_shutdown_task` / `shutdown_all`：set should_exit、cv.notify、join.
- [x] T3.7 `~DCWorldExt()` 调用 `async_climate_shutdown_all()` 兜底.

### Phase 4：注册到 GDScript

- [x] T4.1 `_bind_methods()` 注册 7 个方法 + `D_METHOD` 参数名.

### Phase 5：编译

- [x] T5.1 `cd gdext && scons platform=windows target=template_debug` 通过.

### Phase 6：bench 自动化

- [x] T6.1 创建 `Project/project-keynes/tmp/bench_async_demo_complex.gd`，
       基于 `bench_demo_complex.gd` 模板.
- [x] T6.2 实现 helper：`_run_async_case(n_tasks, grid_w, grid_h, iter, n_warmup, n_measure)`
       返回 5 项均值耗时.
- [x] T6.3 实现 EQ case：异步路径 vs 同步路径在 32×32/iter=4 下逐元素比对，容差 1e-6.
       **实测：max_abs_diff = 0.0（完全 bit-equal）**.
- [x] T6.4 实现 C1-C5 perf 矩阵打印.
       **实测：N=1→12 µs / N=4→30 µs / N=8→56 µs 主线程开销**.
- [x] T6.5 实现 ROBUST：100 次 register/shutdown 循环不死锁 / 不 crash.
       **实测：平均 180 µs/cycle，全部成功**.

### Phase 7：实验报告

- [x] T7.1 跑 bench，记录数据.
- [x] T7.2 写 `docs/cpp-async-experiment-report.md`：7 条判据结论 + 数据 + 推荐.
- [x] T7.3 更新 `docs/cpp-gdscript-best-practices.md` §9，
       把"还没决定"替换成"D 方案实测：12-56 µs / 帧主线程开销，1-8 倍并发可控，推荐量产".
