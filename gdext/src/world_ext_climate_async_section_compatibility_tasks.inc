namespace {

// Error codes set by the worker (read by main thread in poll).
// 0 = ok. Values must be stable — main thread translates them by switch.
constexpr int PK_ASYNC_ERR_OK              = 0;
constexpr int PK_ASYNC_ERR_INVALID_GRID    = 1;
constexpr int PK_ASYNC_ERR_INPUT_SIZE      = 2;

struct AsyncTask {
    int task_id = 0;
    std::thread worker;

    // Inputs (main thread writes under mtx; worker copies to private buffers).
    std::vector<float> in_temp;
    std::vector<float> in_elev;

    // Worker-private buffers (only touched on the worker thread).
    std::vector<float> w_in_temp;
    std::vector<float> w_in_elev;
    std::vector<double> w_buf_a;
    std::vector<double> w_buf_b;
    std::vector<float>  w_out;

    // Result buffer that main thread will memcpy out of in poll().
    std::vector<float> result_buf;

    // Pending request parameters (main writes under mtx; worker reads under mtx).
    int   r_grid_w = 0, r_grid_h = 0;
    int   r_iterations = 16, r_kernel_radius = 2;
    float r_coriolis = 0.5f, r_drag = 0.6f, r_gain = 1.5f, r_k = 0.5f;

    std::mutex mtx;
    std::condition_variable cv;
    std::atomic<bool> request_pending{false};
    std::atomic<bool> result_ready{false};
    std::atomic<bool> should_exit{false};

    // Stats.
    std::atomic<int64_t> last_worker_compute_us{0};
    std::atomic<int64_t> last_worker_total_us{0};
    std::atomic<int64_t> total_ticks{0};
    std::atomic<int64_t> total_reused{0};
    std::atomic<int>     error_code{PK_ASYNC_ERR_OK};
};

struct AsyncState {
    std::unordered_map<int, std::unique_ptr<AsyncTask>> tasks;
    std::mutex tasks_mtx;
};

// ── Pure-C++ kernel — algorithm verbatim from run_demo_complex_pass ────────
// Inputs and outputs are std::vector<float>. Returns false on invalid inputs.
// Knob clamps mirror the synchronous path silently (no push_warning here —
// worker thread cannot call Godot API).
static bool _demo_complex_kernel_pure(int grid_w, int grid_h,
                                      int iterations, int kernel_radius,
                                      float coriolis_strength,
                                      float terrain_drag,
                                      float elevation_gain,
                                      float normalize_k,
                                      const std::vector<float> &T_in_v,
                                      const std::vector<float> &E_v,
                                      std::vector<double> &buf_a,
                                      std::vector<double> &buf_b,
                                      std::vector<float>  &out_v) {
    if (grid_w <= 0 || grid_h <= 0) return false;
    const int n = grid_w * grid_h;
    if ((int)T_in_v.size() != n || (int)E_v.size() != n) return false;

    if (iterations < 1) iterations = 1;
    if (iterations > 64) iterations = 64;
    if (kernel_radius < 1) kernel_radius = 1;
    if (kernel_radius > 5) kernel_radius = 5;
    if (coriolis_strength < -1.0f) coriolis_strength = -1.0f;
    if (coriolis_strength >  1.0f) coriolis_strength =  1.0f;
    if (terrain_drag < 0.0f) terrain_drag = 0.0f;
    if (terrain_drag > 1.0f) terrain_drag = 1.0f;

    if ((int)buf_a.size() != n) buf_a.assign(n, 0.0);
    if ((int)buf_b.size() != n) buf_b.assign(n, 0.0);
    if ((int)out_v.size() != n) out_v.assign(n, 0.0f);

    const float *__restrict T_in = T_in_v.data();
    const float *__restrict E    = E_v.data();

    const int kr   = kernel_radius;
    const int ksz  = 2 * kr + 1;
    double kernel[121];
    double kernel_sum = 0.0;
    for (int dy = -kr; dy <= kr; ++dy) {
        for (int dx = -kr; dx <= kr; ++dx) {
            const double w = simulation_math::exp(-(double)(dx*dx + dy*dy) * 0.5);
            kernel[(dy+kr)*ksz + (dx+kr)] = w;
            kernel_sum += w;
        }
    }
    const double kernel_inv_sum = (kernel_sum > 0.0) ? (1.0 / kernel_sum) : 0.0;

    for (int i = 0; i < n; ++i) buf_a[i] = (double)T_in[i];

    const double step_size = 0.05;
    const double cor  = (double)coriolis_strength;
    const double drag = (double)terrain_drag;

    for (int it = 0; it < iterations; ++it) {
        const std::vector<double> &src = (it & 1) ? buf_b : buf_a;
        std::vector<double>       &dst = (it & 1) ? buf_a : buf_b;
        const double *__restrict S = src.data();
        double       *__restrict D = dst.data();

        for (int y = 0; y < grid_h; ++y) {
            const double cor_sign = (y < grid_h / 2) ? -1.0 : 1.0;
            const double rot_rad  = cor * cor_sign * 1.5707963267948966;

            for (int x = 0; x < grid_w; ++x) {
                const int i = y * grid_w + x;

                double accum = 0.0;
                for (int dy = -kr; dy <= kr; ++dy) {
                    int ny = y + dy;
                    if (ny < 0)         ny = 0;
                    else if (ny >= grid_h) ny = grid_h - 1;
                    const int row = ny * grid_w;
                    const double *kw_row = &kernel[(dy + kr) * ksz];
                    for (int dx = -kr; dx <= kr; ++dx) {
                        int nx = x + dx;
                        if (nx < 0)         nx = 0;
                        else if (nx >= grid_w) nx = grid_w - 1;
                        accum += S[row + nx] * kw_row[dx + kr];
                    }
                }
                const double smooth = accum * kernel_inv_sum;

                const int xw = (x > 0)            ? (x - 1) : x;
                const int xe = (x < grid_w - 1)   ? (x + 1) : x;
                const int yn = (y > 0)            ? (y - 1) : y;
                const int ys = (y < grid_h - 1)   ? (y + 1) : y;
                const int row_n = yn * grid_w;
                const int row_c = y  * grid_w;
                const int row_s = ys * grid_w;
                const double gx = (S[row_n + xe] + 2.0*S[row_c + xe] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0*S[row_c + xw] - S[row_s + xw]) * 0.125;
                const double gy = (S[row_s + xw] + 2.0*S[row_s + x ] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0*S[row_n + x ] - S[row_n + xe]) * 0.125;

                const double cs = simulation_math::cos(rot_rad);
                const double sn = simulation_math::sin(rot_rad);
                const double gx_p = gx * cs - gy * sn;
                const double gy_p = gx * sn + gy * cs;

                const double damp = 1.0 - drag * (double)E[i];
                const double flux = gx_p + gy_p;
                D[i] = smooth + flux * damp * step_size;
            }
        }
    }

    const std::vector<double> &last = (iterations & 1) ? buf_b : buf_a;

    double out_min =  std::numeric_limits<double>::infinity();
    double out_max = -std::numeric_limits<double>::infinity();
    for (int i = 0; i < n; ++i) {
        const double v = last[i];
        if (v < out_min) out_min = v;
        if (v > out_max) out_max = v;
    }
    const double denom = (out_max - out_min) > 1.0e-6
                       ? (out_max - out_min) : 1.0e-6;
    const double inv_denom = 1.0 / denom;

    const double gain = (double)elevation_gain;
    const double k    = (double)normalize_k;
    for (int i = 0; i < n; ++i) {
        const double norm = (last[i] - out_min) * inv_denom;
        const double amp  = 1.0 + gain * (double)E[i];
        double v = norm * amp * k;
        if (v < 0.0) v = 0.0;
        else if (v > 1.0) v = 1.0;
        out_v[i] = (float)v;
    }
    return true;
}

// ── Worker thread main loop ────────────────────────────────────────────────
static void _async_worker_main(AsyncTask *t) {
    using clock = std::chrono::steady_clock;

    while (true) {
        // Snapshot params under the lock, then release it during compute.
        int   grid_w, grid_h, iters, kr;
        float coriolis, drag, gain, k;
        {
            std::unique_lock<std::mutex> lk(t->mtx);
            t->cv.wait(lk, [t]{
                return t->request_pending.load(std::memory_order_acquire)
                    || t->should_exit.load(std::memory_order_acquire);
            });
            if (t->should_exit.load(std::memory_order_acquire)) return;

            // Copy inputs into worker-private buffers (cheap; ~9.6 KB at 60×40).
            t->w_in_temp = t->in_temp;
            t->w_in_elev = t->in_elev;
            grid_w = t->r_grid_w;
            grid_h = t->r_grid_h;
            iters  = t->r_iterations;
            kr     = t->r_kernel_radius;
            coriolis = t->r_coriolis;
            drag     = t->r_drag;
            gain     = t->r_gain;
            k        = t->r_k;
        }

        const auto t0 = clock::now();
        const auto t_compute_start = clock::now();

        const bool ok = _demo_complex_kernel_pure(
            grid_w, grid_h, iters, kr,
            coriolis, drag, gain, k,
            t->w_in_temp, t->w_in_elev,
            t->w_buf_a, t->w_buf_b, t->w_out);

        const auto t_compute_end = clock::now();

        if (!ok) {
            // Set error code; do not modify result_buf (keep last good result).
            t->error_code.store(PK_ASYNC_ERR_INPUT_SIZE,
                                std::memory_order_release);
        } else {
            // Publish: copy w_out → result_buf under lock (so main-thread poll
            // never sees a partially-written buffer).
            std::lock_guard<std::mutex> lk(t->mtx);
            t->result_buf.resize(t->w_out.size());
            std::memcpy(t->result_buf.data(), t->w_out.data(),
                        t->w_out.size() * sizeof(float));
            t->error_code.store(PK_ASYNC_ERR_OK, std::memory_order_release);
        }

        const auto t1 = clock::now();
        t->last_worker_compute_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                t_compute_end - t_compute_start).count(),
            std::memory_order_relaxed);
        t->last_worker_total_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                t1 - t0).count(),
            std::memory_order_relaxed);
        t->total_ticks.fetch_add(1, std::memory_order_relaxed);

        t->request_pending.store(false, std::memory_order_release);
        t->result_ready.store(true, std::memory_order_release);
    }
}

inline AsyncState *_get_or_create_async_state(void *&slot) {
    if (!slot) slot = new AsyncState();
    return reinterpret_cast<AsyncState*>(slot);
}

inline AsyncState *_get_async_state(void *slot) {
    return reinterpret_cast<AsyncState*>(slot);
}

} // namespace (anonymous)

// ── Public API ────────────────────────────────────────────────────────────

void DCWorldExt::async_climate_register_task(int task_id, int n_workers) {
    (void)n_workers; // currently always 1 — multi-worker per task left for future
    AsyncState *st = _get_or_create_async_state(_async_state);
    std::lock_guard<std::mutex> g(st->tasks_mtx);
    auto it = st->tasks.find(task_id);
    if (it != st->tasks.end()) {
        UtilityFunctions::push_warning(
            "[DCWorldExt][async] task ", task_id,
            " already registered; ignoring duplicate register");
        return;
    }
    auto t = std::make_unique<AsyncTask>();
    t->task_id = task_id;
    AsyncTask *raw = t.get();
    st->tasks.emplace(task_id, std::move(t));
    raw->worker = std::thread(&_async_worker_main, raw);
}

void DCWorldExt::async_climate_set_inputs(int task_id,
                                          const PackedFloat32Array &temp,
                                          const PackedFloat32Array &elev) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        UtilityFunctions::push_warning("[DCWorldExt][async] set_inputs: no async state");
        return;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            UtilityFunctions::push_warning(
                "[DCWorldExt][async] set_inputs: task ", task_id, " not registered");
            return;
        }
        t = it->second.get();
    }
    const int n_t = temp.size();
    const int n_e = elev.size();
    std::lock_guard<std::mutex> lk(t->mtx);
    t->in_temp.resize(n_t);
    if (n_t > 0) std::memcpy(t->in_temp.data(), temp.ptr(), n_t * sizeof(float));
    t->in_elev.resize(n_e);
    if (n_e > 0) std::memcpy(t->in_elev.data(), elev.ptr(), n_e * sizeof(float));
}

void DCWorldExt::async_climate_request(int task_id,
                                       int grid_w, int grid_h,
                                       int iterations, int kernel_radius,
                                       float coriolis_strength,
                                       float terrain_drag,
                                       float elevation_gain,
                                       float normalize_k) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        UtilityFunctions::push_warning("[DCWorldExt][async] request: no async state");
        return;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            UtilityFunctions::push_warning(
                "[DCWorldExt][async] request: task ", task_id, " not registered");
            return;
        }
        t = it->second.get();
    }
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        // If a previous request is still in flight or unread, count this main
        // thread tick as a "reuse" frame (worker not keeping up). The main
        // thread will keep using the last-published result until poll picks it.
        if (t->request_pending.load(std::memory_order_acquire)) {
            t->total_reused.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        t->r_grid_w = grid_w;
        t->r_grid_h = grid_h;
        t->r_iterations = iterations;
        t->r_kernel_radius = kernel_radius;
        t->r_coriolis = coriolis_strength;
        t->r_drag = terrain_drag;
        t->r_gain = elevation_gain;
        t->r_k    = normalize_k;
        t->request_pending.store(true, std::memory_order_release);
    }
    t->cv.notify_one();
}

bool DCWorldExt::async_climate_poll(int task_id) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return false;
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) return false;
        t = it->second.get();
    }
    if (!t->result_ready.load(std::memory_order_acquire)) return false;

    // Translate any pending error from the worker into a single push_warning
    // (called on the main thread → safe to call Godot API).
    const int ec = t->error_code.exchange(PK_ASYNC_ERR_OK, std::memory_order_acq_rel);
    if (ec != PK_ASYNC_ERR_OK) {
        UtilityFunctions::push_warning(
            "[DCWorldExt][async] worker error code=", ec, " (task ", task_id, ")");
        // Do NOT consume result_ready on error; main thread sees stale result.
        return false;
    }

    // Snapshot result_buf under lock; copy into _slots[CELL_DEMO_THERMAL_GRADIENT].
    std::vector<float> snapshot;
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        snapshot = t->result_buf;
    }
    t->result_ready.store(false, std::memory_order_release);

    const int sid_out = component_id(StringName("cell_demo_thermal_gradient"));
    if (sid_out < 0) return true; // no output slot — client just got the timing info
    Slot &s_out = _slots.write[sid_out];
    if (s_out.dtype != SlotDType::F32) return true;
    const int n_slot = s_out.arr_f32.size();
    const int n_snap = (int)snapshot.size();
    if (n_slot != n_snap || n_slot <= 0) return true;
    float *p = s_out.arr_f32.ptrw();
    std::memcpy(p, snapshot.data(), n_slot * sizeof(float));
    return true;
}

Dictionary DCWorldExt::async_climate_stats(int task_id) {
    Dictionary d;
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        d["registered"] = false;
        return d;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            d["registered"] = false;
            return d;
        }
        t = it->second.get();
    }
    d["registered"] = true;
    d["worker_compute_us"] = (int64_t)t->last_worker_compute_us.load(std::memory_order_relaxed);
    d["worker_total_us"]   = (int64_t)t->last_worker_total_us.load(std::memory_order_relaxed);
    d["total_ticks"]       = (int64_t)t->total_ticks.load(std::memory_order_relaxed);
    d["total_reused"]      = (int64_t)t->total_reused.load(std::memory_order_relaxed);
    d["request_pending"]   = t->request_pending.load(std::memory_order_acquire);
    d["result_ready"]      = t->result_ready.load(std::memory_order_acquire);
    return d;
}

void DCWorldExt::async_climate_shutdown_task(int task_id) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return;
    std::unique_ptr<AsyncTask> owned;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) return;
        owned = std::move(it->second);
        st->tasks.erase(it);
    }
    // Signal the worker to exit then join. cv.notify_one BEFORE join.
    owned->should_exit.store(true, std::memory_order_release);
    owned->cv.notify_all();
    if (owned->worker.joinable()) owned->worker.join();
}

void DCWorldExt::async_climate_shutdown_all() {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return;
    // Move out all tasks under lock so the destructors run unlocked.
    std::vector<std::unique_ptr<AsyncTask>> dead;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        dead.reserve(st->tasks.size());
        for (auto &kv : st->tasks) dead.push_back(std::move(kv.second));
        st->tasks.clear();
    }
    for (auto &t : dead) {
        t->should_exit.store(true, std::memory_order_release);
        t->cv.notify_all();
    }
    for (auto &t : dead) {
        if (t->worker.joinable()) t->worker.join();
    }
    delete st;
    _async_state = nullptr;
}
