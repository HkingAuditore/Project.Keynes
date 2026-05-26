# GDScript → C++ 移植步骤详细清单

> **创建时间**: 2026-05-26  
> **目标**: 逐个列出所有移植步骤，确保可执行、可验收  
> **总预估工作量**: ~17 个工作日

---

## 📋 总览表

| 优先级 | 函数 | 当前延迟 | 目标延迟 | 预估工作量 | 步骤数 |
|--------|------|----------|----------|------------|--------|
| **P0** | `solve_wind_field` | ~35ms | <5ms | 3-5 天 | 12 步 |
| **P0** | `solve_ocean_psi` | ~20ms | <5ms | 2-3 天 | 10 步 |
| **P1** | `solve_slp_field` | ~3ms | <1ms | 1-2 天 | 8 步 |
| **P1** | `solve_wind_stress_curl` | ~2ms | <0.5ms | 1 天 | 8 步 |
| **P1** | `distribute_weather_field` | ~1.5ms | <0.5ms | 2-3 天 | 10 步 |
| **P1** | `build_field_summary_fronts` | ~3ms | <1ms | 3-5 天 | 12 步 |
| **P2** | `psi_to_ocean_current` | ~1ms | <0.3ms | 1 天 | 6 步 |
| **P2** | `solve_upwelling` | ~1ms | <0.3ms | 1 天 | 6 步 |

**总计**: ~17 个工作日，消除 **66ms** 热路径延迟

---

## 🔴 P0 - `solve_wind_field` 移植步骤 (35ms → <5ms)

### **预估工作量**: 3-5 天  
### **预期收益**: **7× 性能提升**

---

### **Step 1: 代码审查与算法理解** ⏱️ 0.5 天

**目标**: 完全理解 `physical_circulation_solver.gd:258-454` 的算法

**任务**:
- [ ] 阅读 `solve_wind_field` 完整代码 (197 行)
- [ ] 绘制算法流程图 (6 个步骤)
- [ ] 标识所有数组访问 (读/写)
- [ ] 标识所有 Godot API 调用 (需要替换)
- [ ] 计算理论操作数: N × 36 = 2400 × 36 = 86,400

**输出**:
```
algo_wind_field.md - 算法详细注释版
```

**验收**: 能向他人清晰解释算法每一步

---

### **Step 2: 创建 C++ 函数签名** ⏱️ 0.5 小时

**文件**: `gdext/src/world_ext.h`

**代码**:
```cpp
// ─── Ocean Wind C++ Acceleration (Block B) ─────────────────────────────
// Solves physical wind field on hex grid.
// Returns 0.0 on success, -1.0 on fallback.
double solve_wind_field_cpp(const Dictionary &knobs);
```

**验收**: 编译通过 (无链接错误)

---

### **Step 3: 实现 Precondition 检查** ⏱️ 1 小时

**文件**: `gdext/src/world_ext.cpp`

**代码**:
```cpp
double DCWorldExt::solve_wind_field_cpp(const Dictionary &knobs) {
    // 1. Hard preconditions
    if (!_bound) {
        diag("solve_wind_field: not _bound");
        return -1.0;
    }
    
    // 2. Resolve all slot ids
    const int sid_slp     = component_id(StringName("cell_slp"));
    const int sid_wind_vx = component_id(StringName("cell_wind_vec_x"));
    const int sid_wind_vy = component_id(StringName("cell_wind_vec_y"));
    const int sid_wind_sp = component_id(StringName("cell_wind_speed"));
    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_pos_x   = component_id(StringName("cell_pos_x"));
    const int sid_pos_y   = component_id(StringName("cell_pos_y"));
    const int sid_neighbor = component_id(StringName("cell_neighbor_0")); // 6 slots
    
    if (sid_slp < 0 || sid_wind_vx < 0 || sid_wind_vy < 0 || 
        sid_wind_sp < 0 || sid_terrain < 0 || sid_landform < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0 || sid_neighbor < 0) {
        diag("solve_wind_field: missing slot id");
        return -1.0;
    }
    
    // 3. Pull arrays & validate
    PackedFloat32Array slp_arr     = view_f32(sid_slp);
    PackedFloat32Array wind_vx_arr = view_f32(sid_wind_vx);
    PackedFloat32Array wind_vy_arr = view_f32(sid_wind_vy);
    PackedFloat32Array wind_sp_arr = view_f32(sid_wind_sp);
    PackedInt32Array   terrain_arr  = view_i32(sid_terrain);
    PackedInt32Array   landform_arr = view_i32(sid_landform);
    PackedFloat32Array pos_x_arr   = view_f32(sid_pos_x);
    PackedFloat32Array pos_y_arr   = view_f32(sid_pos_y);
    
    const int n_cells = slp_arr.size();
    if (n_cells <= 0 || wind_vx_arr.size() != n_cells) {
        diag("solve_wind_field: array size mismatch");
        return -1.0;
    }
    
    // 4. Pull scalars from knobs
    if (!knobs.has("hex_size") || !knobs.has("season_phase") || 
        !knobs.has("terrain_aware")) {
        diag("solve_wind_field: missing knobs");
        return -1.0;
    }
    const float hex_size     = float(knobs["hex_size"]);
    const float season_phase = float(knobs["season_phase"]);
    const bool  terrain_aware = bool(knobs["terrain_aware"]);
    
    // TODO: Implement actual algorithm
    return -1.0;  // Fallback to GDScript for now
}
```

**验收**: 
- [ ] 编译通过
- [ ] Godot 中调用返回 -1.0 (fallback)

---

### **Step 4: 注册到 ClassDB** ⏱️ 0.5 小时

**文件**: `gdext/src/world_ext.cpp`

**代码**:
```cpp
void DCWorldExt::_bind_methods() {
    // ... existing binds ...
    
    // Ocean Wind C++ Acceleration (Block B)
    ClassDB::bind_method(D_METHOD("solve_wind_field_cpp", "knobs"), 
                         &DCWorldExt::solve_wind_field_cpp);
}
```

**验收**: 
- [ ] 编译通过
- [ ] Godot 编辑器中能看到 `solve_wind_field_cpp` 方法

---

### **Step 5: GDScript 端添加 C++ 路径调用** ⏱️ 1 小时

**文件**: `scripts/weather/physical_circulation_solver.gd:258`

**代码**:
```gdscript
static func solve_wind_field(map: MapData, hex_size: float, world_bounds: Rect2, \
        season_phase: float, terrain_aware: bool = true) -> void:
    
    # Try C++ path first
    if Engine.has_singleton("DCWorldExt"):
        var ext = Engine.get_singleton("DCWorldExt")
        if ext != null and ext.has_method("solve_wind_field_cpp"):
            var knobs = {
                "hex_size": hex_size,
                "season_phase": season_phase,
                "terrain_aware": terrain_aware,
                "world_bounds_x": world_bounds.position.x,
                "world_bounds_y": world_bounds.position.y,
                "world_bounds_w": world_bounds.size.x,
                "world_bounds_h": world_bounds.size.y,
            }
            var rc = ext.solve_wind_field_cpp(knobs)
            if rc >= 0.0:
                return  # C++ 路径成功
    
    # Fallback to GDScript (original implementation)
    # ... original code ...
```

**验收**:
- [ ] Godot 启动无错误
- [ ] C++ 返回 -1.0 时正确 fallback

---

### **Step 6: 实现 Pass 0 - BFS 海岸距离计算** ⏱️ 0.5 天

**算法**: 从海岸线单元格出发，BFS 计算所有陆地单元格到海岸的距离

**C++ 代码**:
```cpp
// Pass 0: BFS coast distance (O(N_land × 5))
PackedInt32Array terrain_arr = view_i32(sid_terrain);
PackedFloat32Array coast_dist_arr = PackedFloat32Array();
coast_dist_arr.resize(n_cells);

// TODO: Implement BFS using precomputed neighbor indices
// For now, fallback
return -1.0;
```

**验收**:
- [ ] 单元测试: 验证 BFS 距离计算正确性
- [ ] 性能测试: <1ms for N=2400

---

### **Step 7: 实现 Pass (a) - 纬度基线** ⏱️ 0.5 天

**算法**: 根据纬度计算地转风基线 (sin(2φ) 项)

**C++ 代码**:
```cpp
// Pass (a): Latitude baseline (O(N))
const float beta_param = 1.43e-5;  // From GDScript
const float f_param = 2.0 * beta_param * 6371e3 / 360.0 * 180.0 / PI;

#pragma omp parallel for
for (int i = 0; i < n_cells; ++i) {
    float lat = pos_y_arr[i];  // Assume y = latitude
    float base_wind = f_param * sin(2.0 * lat * PI / 180.0);
    // Store to temporary array
}
```

**验收**:
- [ ] Bit-equal 测试: 与 GDScript 输出误差 < 1e-3
- [ ] 性能测试: <0.5ms for N=2400

---

### **Step 8: 实现 Pass (b) - 6×6 邻域梯度 (瓶颈 1)** ⏱️ 1 天

**算法**: 每个单元格遍历 6 个邻居，每个邻居再遍历 6 个邻居 = 36 次访问

**C++ 代码 (OpenMP + SIMD)**:
```cpp
// Pass (b): 6×6 neighborhood gradient (O(N × 36))
#pragma omp parallel for
for (int i = 0; i < n_cells; ++i) {
    float grad_x = 0.0f;
    float grad_y = 0.0f;
    
    // TODO: Use precomputed neighbor indices
    // For now, assume we have neighbor_indices[i][6]
    for (int d1 = 0; d1 < 6; ++d1) {
        int n1 = neighbor_indices[i][d1];
        if (n1 < 0) continue;
        
        for (int d2 = 0; d2 < 6; ++d2) {
            int n2 = neighbor_indices[n1][d2];
            if (n2 < 0) continue;
            
            // Gradient calculation
            float slp_diff = slp_arr[n2] - slp_arr[i];
            grad_x += slp_diff * (pos_x_arr[n2] - pos_x_arr[i]);
            grad_y += slp_diff * (pos_y_arr[n2] - pos_y_arr[i]);
        }
    }
    
    // Store gradient
    temp_grad_x[i] = grad_x;
    temp_grad_y[i] = grad_y;
}
```

**优化**:
- [ ] 预计算 neighbor_indices 数组 (避免每 tick 重建)
- [ ] OpenMP 并行化 (`#pragma omp parallel for`)
- [ ] SIMD 向量化 (AVX2: 8× float32)

**验收**:
- [ ] 性能测试: **<5ms** for N=2400 (目标: 从 35ms 降低)
- [ ] Bit-equal 测试: 误差 < 1e-3

---

### **Step 9: 实现 Pass (c) - 海陆季风加权** ⏱️ 0.5 天

**算法**: 根据陆地/海洋比例调整风场

**C++ 代码**:
```cpp
// Pass (c): Land-sea monsoon weighting (O(N))
#pragma omp parallel for
for (int i = 0; i < n_cells; ++i) {
    float land_ratio = (terrain_arr[i] == 1) ? 1.0f : 0.0f;  // Simplified
    float monsoon_factor = 1.0f + 0.3f * land_ratio * cos(season_phase);
    
    wind_vx_arr[i] *= monsoon_factor;
    wind_vy_arr[i] *= monsoon_factor;
}
```

**验收**:
- [ ] Bit-equal 测试: 误差 < 1e-3
- [ ] 性能测试: <0.5ms

---

### **Step 10: 实现 Pass (d) - 科氏旋转** ⏱️ 0.5 天

**算法**: 应用科氏力偏转 (f × wind)

**C++ 代码**:
```cpp
// Pass (d): Coriolis rotation (O(N))
const float coriolis_param = 1e-4;  // From GDScript

#pragma omp parallel for
for (int i = 0; i < n_cells; ++i) {
    float lat = pos_y_arr[i];
    float f = 2.0 * coriolis_param * sin(lat * PI / 180.0);
    
    float new_vx = wind_vx_arr[i] - f * wind_vy_arr[i];
    float new_vy = wind_vy_arr[i] + f * wind_vx_arr[i];
    
    wind_vx_arr[i] = new_vx;
    wind_vy_arr[i] = new_vy;
}
```

**验收**:
- [ ] Bit-equal 测试: 误差 < 1e-3
- [ ] 性能测试: <0.5ms

---

### **Step 11: 实现 Pass (e) - 地形摩擦 + 山脉绕流 (瓶颈 2)** ⏱️ 1 天

**算法**: 陆地单元格额外 6×6 遍历 + 地形查表

**C++ 代码**:
```cpp
// Pass (e): Terrain friction + mountain bypass (O(N_land × 36))
#pragma omp parallel for
for (int i = 0; i < n_cells; ++i) {
    if (terrain_arr[i] != 1) continue;  // Only land cells
    
    int landform = landform_arr[i];
    float friction = 1.0f;
    
    // Terrain friction lookup
    if (landform == 2) friction = 0.7f;       // Hills
    else if (landform == 3) friction = 0.4f;  // Mountains
    else if (landform == 4) friction = 0.2f;  // High mountains
    
    // 6×6 neighborhood terrain bypass
    // TODO: Implement actual bypass logic
    
    wind_vx_arr[i] *= friction;
    wind_vy_arr[i] *= friction;
}
```

**验收**:
- [ ] 性能测试: **<3ms** for N_land=1200
- [ ] Bit-equal 测试: 误差 < 1e-3

---

### **Step 12: 性能验证与回归测试** ⏱️ 1 天

**任务**:
- [ ] 运行 `DCSoakABRunner` 30 天模拟
- [ ] 比较 C++ vs GDScript 输出 (bit-equal)
- [ ] 性能基准测试 (p95 延迟)
- [ ] 修复所有回归 bug

**验收标准**:
| 指标 | 目标 | 实际 |
|------|------|------|
| p95 延迟 | <5ms | ______ |
| Bit-equal 误差 | <1e-3 | ______ |
| 单元测试 | ALL PASS | ______ |

**输出**:
```
perf_wind_field_cpp_vs_gdscript.csv
```

---

## 🔴 P0 - `solve_ocean_psi` 移植步骤 (20ms → <5ms)

### **预估工作量**: 2-3 天  
### **预期收益**: **4× 性能提升**

---

### **Step 1: 代码审查与算法理解** ⏱️ 0.5 天

**目标**: 理解 SOR 迭代求解 ∇²ψ + R·∂ψ/∂x = -ω/β

**任务**:
- [ ] 阅读 `physical_circulation_solver.gd:489-700` (211 行)
- [ ] 理解 SOR 迭代公式
- [ ] 标识所有数组访问
- [ ] 确定并行化策略 (OpenMP vs GPU Compute)

**输出**:
```
algo_ocean_psi.md - SOR 迭代详细注释
```

---

### **Step 2: 创建 C++ 函数签名** ⏱️ 0.5 小时

**文件**: `gdext/src/world_ext.h`

**代码**:
```cpp
// Solves ocean stream function psi using SOR iteration.
// Returns 0.0 on success, -1.0 on fallback.
double solve_ocean_psi_cpp(const Dictionary &knobs);
```

---

### **Step 3: 实现 Precondition + SOR 迭代 (OpenMP)** ⏱️ 1.5 天

**算法**: 
1. 初始化 ψ 数组
2. SOR 迭代 40-80 次
3. 每次迭代: 棋盘着色避免读写冲突
4. 收敛条件: max_delta < tolerance

**C++ 代码 (OpenMP 并行)**:
```cpp
double DCWorldExt::solve_ocean_psi_cpp(const Dictionary &knobs) {
    // 1. Precondition checks (similar to solve_wind_field)
    // ...
    
    // 2. SOR iteration with checkerboard coloring
    const int max_iter = 80;
    const float omega = 1.8f;  // SOR relaxation factor
    const float tolerance = 1e-6f;
    
    PackedFloat32Array psi_arr = view_f32(sid_psi);
    PackedFloat32Array wind_curl_arr = view_f32(sid_wind_curl);
    
    for (int iter = 0; iter < max_iter; ++iter) {
        float max_delta = 0.0f;
        
        // Checkerboard coloring: even cells
        #pragma omp parallel for reduction(max:max_delta)
        for (int i = 0; i < n_cells; i += 2) {
            float old_psi = psi_arr[i];
            
            // SOR update formula
            float new_psi = compute_sor_update(i, psi_arr, wind_curl_arr);
            psi_arr[i] = old_psi + omega * (new_psi - old_psi);
            
            max_delta = fmaxf(max_delta, fabsf(psi_arr[i] - old_psi));
        }
        
        // Checkerboard coloring: odd cells
        #pragma omp parallel for reduction(max:max_delta)
        for (int i = 1; i < n_cells; i += 2) {
            // Same as above
        }
        
        // Check convergence
        if (max_delta < tolerance) break;
    }
    
    return 0.0;
}
```

**优化**:
- [ ] 棋盘着色并行化 (避免读写冲突)
- [ ] OpenMP `reduction(max:max_delta)`
- [ ] 预计算邻居索引

**验收**:
- [ ] 性能测试: **<5ms** for 40 次迭代
- [ ] 数值验证: ψ 场与 GDScript 误差 < 1e-3

---

### **Step 4: (可选) GPU Compute Shader 实现** ⏱️ 2-3 天

**适用场景**: 如果 OpenMP 版本不够快，可以卸载到 GPU

**任务**:
- [ ] 编写 GLSL compute shader
- [ ] 每个迭代: 1 个 dispatch
- [ ] 40 次迭代: 40 个 dispatch (~2-3ms 总计)

**验收**:
- [ ] 性能测试: **<3ms** for 40 次迭代
- [ ] 数值验证: 与 CPU 版本误差 < 1e-4

---

### **Step 5: GDScript 端调用 + 回归测试** ⏱️ 0.5 天

**任务**:
- [ ] 修改 `physical_circulation_solver.gd` 调用 C++ 路径
- [ ] 运行 `DCSoakABRunner` 验证
- [ ] 修复 bug

**验收**: 同 `solve_wind_field` Step 12

---

## 🟡 P1 - `solve_slp_field` 移植步骤 (3ms → <1ms)

### **预估工作量**: 1-2 天  
### **预期收益**: **3× 性能提升**

---

### **Step 1-8: 简化版移植** ⏱️ 1-2 天

**算法**: 海陆压力场 + Jacobi 平滑 (6 邻域)

**关键步骤**:
1. 代码审查 (0.5 天)
2. C++ 函数签名 (0.5 小时)
3. Precondition 检查 (1 小时)
4. 实现海陆压力场 (0.5 天)
5. 实现 Jacobi 平滑 (0.5 天)
6. OpenMP 并行化 (2 小时)
7. GDScript 端调用 (1 小时)
8. 性能验证 (0.5 天)

**验收**:
- [ ] p95 延迟: **<1ms**
- [ ] Bit-equal 误差: <1e-3

---

## 🟡 P1 - `solve_wind_stress_curl` 移植步骤 (2ms → <0.5ms)

### **预估工作量**: 1 天  
### **预期收益**: **4× 性能提升**

---

### **Step 1-8: 极简移植** ⏱️ 1 天

**算法**: 风应力旋度计算 (O(N×6))

**关键步骤**:
1. 代码审查 (0.2 天)
2. C++ 实现 (0.5 天)
3. OpenMP 并行化 (0.5 小时)
4. GDScript 端调用 (0.5 小时)
5. 性能验证 (0.5 小时)

**验收**:
- [ ] p95 延迟: **<0.5ms**
- [ ] Bit-equal 误差: <1e-3

---

## 🟡 P1 - `distribute_weather_field_to_cells` 移植步骤 (1.5ms → <0.5ms)

### **预估工作量**: 2-3 天  
### **预期收益**: **3× 性能提升**

---

### **Step 1-10: 补全 C++ Stub** ⏱️ 2-3 天

**现状**: 已有 `run_weather_distribute_pass` stub，需补全实现

**关键步骤**:
1. 代码审查 (0.5 天)
2. 补全 C++ 实现 (1.5 天)
3. 写位数组映射 (0.5 天)
4. GDScript 端调用 (0.5 小时)
5. 性能验证 (0.5 天)

**验收**:
- [ ] p95 延迟: **<0.5ms**
- [ ] Bit-equal 误差: <1e-3

---

## 🟡 P1 - `build_field_summary_fronts` 移植步骤 (3ms → <1ms)

### **预估工作量**: 3-5 天  
### **预期收益**: **3× 性能提升**

---

### **Step 1-12: 复杂逻辑移植** ⏱️ 3-5 天

**算法**: 从网格天气场提取锋面摘要 (cluster + NMS)

**关键步骤**:
1. 代码审查 (1 天) - **最复杂**，480 行
2. 重构算法 (0.5 天) - 拆分 cluster + NMS
3. C++ 实现 cluster (1 天)
4. C++ 实现 NMS (0.5 天)
5. OpenMP 并行化 (0.5 天)
6. GDScript 端调用 (0.5 小时)
7. 性能验证 (0.5 天)

**验收**:
- [ ] p95 延迟: **<1ms**
- [ ] 锋面位置误差: <0.5 像素

---

## 🟢 P2 - `psi_to_ocean_current` 移植步骤 (1ms → <0.3ms)

### **预估工作量**: 1 天  
### **预期收益**: **3× 性能提升**

---

### **Step 1-6: 简单数值移植** ⏱️ 1 天

**算法**: ψ 转洋流速度 (O(N), <1ms)

**关键步骤**:
1. 代码审查 (0.2 天)
2. C++ 实现 (0.5 天)
3. GDScript 端调用 (0.5 小时)
4. 性能验证 (0.5 小时)

**验收**:
- [ ] p95 延迟: **<0.3ms**

---

## 🟢 P2 - `solve_upwelling` 移植步骤 (1ms → <0.3ms)

### **预估工作量**: 1 天  
### **预期收益**: **3× 性能提升**

---

### **Step 1-6: Ekman 抽吸移植** ⏱️ 1 天

**算法**: Ekman 抽吸 + 涌升流 (O(N), ~1ms)

**关键步骤**: 同 `psi_to_ocean_current`

**验收**:
- [ ] p95 延迟: **<0.3ms**

---

## 📊 总结与建议

### **推荐执行顺序**:

| Week | 任务 | 预期收益 |
|------|------|----------|
| **W1** | `solve_wind_field` Step 1-12 | 35ms → 5ms (**7×**) |
| **W2** | `solve_ocean_psi` Step 1-5 | 20ms → 5ms (**4×**) |
| **W3** | 性能验证 + bug 修复 | - |
| **W4** | `distribute` + `summary` | 4.5ms → 1ms (**4.5×**) |
| **W5** | `solve_slp_field` + `solve_wind_stress_curl` | 5ms → 1ms (**5×**) |
| **W6** | 性能验证 + 回归测试 | - |

**总计**: ~17 个工作日，消除 **66ms** 热路径延迟

---

### **成功指标**:

- [ ] **性能**: p95 延迟降低 **5-10×**
- [ ] **正确性**: bit-equal 误差 < 1e-3
- [ ] **稳定性**: 30 天 soak 无回归
- [ ] **可维护性**: 详细注释 + 单元测试

---

**下一步**: 开始执行 `solve_wind_field` Step 1 (代码审查)
