# -*- coding: utf-8 -*-
"""把 run_weather_field_commit_pass 的计算体原样搬进 runtime_climate_passes.cpp
的 weather_commit_pure，只做机械改名。

对应 plan P3：worker 硬编码 use_next_outputs=false 走 direct 分支，生产走 staged
分支（solve → commit），两边在同一 stage 上跑不同代码。commit 提成共享内核后
worker 才能跟生产同路。
"""
import io

SRC = 'gdext/src/world_ext_weather.cpp'
DST = 'gdext/src/runtime_climate_passes.cpp'

src = io.open(SRC, encoding='utf-8').read().split('\n')

# 计算体：`for (int i = 0; i < n_cells; ++i) { W_DIRTY[i] = 0; }` 起，
# 到主循环闭合（_flush_slot_to_map 之前）为止。
start = next(i for i, l in enumerate(src)
             if l.strip() == 'W_DIRTY[i] = 0;')
start -= 1  # 回到 for 头
end = next(i for i, l in enumerate(src)
           if i > start and '_flush_slot_to_map(sid_w_intens)' in l)
body = src[start:end]
while body and not body[-1].strip():
    body.pop()

text = '\n'.join(body)

# ── 机械改名 ──
# 1) PackedFloat32Array convergence_deltas 那一段换成 lanes.convergence_deltas
text = text.replace(
    '''    int dirty_count = 0;
    int convergence_dirty_count = 0;
    PackedFloat32Array convergence_deltas;
    if (refresh_convergence) {
        convergence_deltas.resize(n_cells);
    }
    float * const __restrict CONV_DELTA =
        refresh_convergence ? convergence_deltas.ptrw() : nullptr;
    double water_budget_error_acc = 0.0;''',
    '''    int dirty_count = 0;
    int convergence_dirty_count = 0;
    float * const __restrict CONV_DELTA =
        refresh_convergence ? lanes.convergence_deltas : nullptr;
    double water_budget_error_acc = 0.0;''')

prologue = [
    '    // ── 前言：把 knobs/lanes 摊回生产里的局部名，计算体得以原样保留 ──',
    '    const int n_cells = knobs.n_cells;',
    '    const bool refresh_convergence = knobs.refresh_convergence;',
    '    const bool weather_transition_enabled = knobs.weather_transition_enabled;',
    '    const float transition_rate = knobs.transition_rate;',
    '    const float transition_dt_days = knobs.transition_dt_days;',
    '',
    '    const int32_t * const __restrict NB = lanes.neighbor_indices;',
    '    const float * const __restrict PREV_VAP = lanes.prev_vapor;',
    '    const float * const __restrict NEXT_VAP = lanes.next_vapor;',
    '    const float * const __restrict NEXT_CLD = lanes.next_cloud;',
    '    const float * const __restrict NEXT_CW = lanes.next_cloud_water;',
    '    const float * const __restrict NEXT_PRE = lanes.next_precip;',
    '    const float * const __restrict NEXT_INS = lanes.next_instability;',
    '    const float * const __restrict NEXT_INT = lanes.next_intensity;',
    '    const float * const __restrict NEXT_CNV = lanes.next_convergence;',
    '    const int32_t * const __restrict NEXT_TYP = lanes.next_type;',
    '',
    '    float * const __restrict W_INT = lanes.intensity;',
    '    float * const __restrict W_CLD = lanes.cloud;',
    '    float * const __restrict W_CW = lanes.cloud_water;',
    '    float * const __restrict W_PRE = lanes.precip;',
    '    uint8_t * const __restrict W_TYP = lanes.type;',
    '    uint8_t * const __restrict W_PREV = lanes.prev_type;',
    '    uint8_t * const __restrict W_TARGET = lanes.target_type;',
    '    float * const __restrict W_ALPHA = lanes.transition_alpha;',
    '    float * const __restrict W_VAP = lanes.vapor;',
    '    float * const __restrict W_CNV = lanes.convergence;',
    '    float * const __restrict W_INS = lanes.instability;',
    '    uint8_t * const __restrict W_FIN = lanes.field_init;',
    '    uint8_t * const __restrict W_DIRTY = lanes.dirty;',
    '',
    '    // LUT 是纯输出；生产总会给一块 lut_slots*4 的 buffer，worker 可以不要。',
    '    uint8_t * const __restrict WX = lanes.lut;',
    '    auto q01_byte_commit = [](float v) -> uint8_t {',
    '        if (v <= 0.0f) return uint8_t(0);',
    '        if (v >= 1.0f) return uint8_t(255);',
    '        return uint8_t(std::clamp(int(std::round(double(v) * 255.0)), 0, 255));',
    '    };',
    '',
]

fn = []
fn.append('void weather_commit_pure(const WeatherCommitKnobs &knobs,')
fn.append('                         const WeatherCommitLanes &lanes,')
fn.append('                         WeatherCommitStats &stats) {')
fn.append('    stats = WeatherCommitStats{};')
fn.append('    if (knobs.n_cells <= 0) return;')
fn.append('    if (lanes.next_vapor == nullptr || lanes.next_cloud == nullptr ||')
fn.append('        lanes.next_precip == nullptr || lanes.next_instability == nullptr ||')
fn.append('        lanes.next_intensity == nullptr || lanes.next_convergence == nullptr ||')
fn.append('        lanes.next_type == nullptr || lanes.prev_vapor == nullptr ||')
fn.append('        lanes.neighbor_indices == nullptr) {')
fn.append('        return;')
fn.append('    }')
fn.append('    if (lanes.intensity == nullptr || lanes.cloud == nullptr ||')
fn.append('        lanes.precip == nullptr || lanes.vapor == nullptr ||')
fn.append('        lanes.convergence == nullptr || lanes.instability == nullptr ||')
fn.append('        lanes.type == nullptr || lanes.field_init == nullptr ||')
fn.append('        lanes.dirty == nullptr) {')
fn.append('        return;')
fn.append('    }')
fn.extend(prologue)
fn.append(text)
fn.append('')
fn.append('    stats.dirty_count = dirty_count;')
fn.append('    stats.convergence_dirty_count = convergence_dirty_count;')
fn.append('    stats.water_budget_error_sum = water_budget_error_acc;')
fn.append('}')
fn.append('')

kernel = '\n'.join(fn)

dst = io.open(DST, encoding='utf-8').read()
anchor = '// weather distribute'
idx = dst.index(anchor)
dst = dst[:idx] + kernel + '\n' + dst[idx:]
io.open(DST, 'w', encoding='utf-8', newline='\n').write(dst)
print('inserted weather_commit_pure, %d lines transplanted (src %d-%d)'
      % (len(body), start + 1, end))
