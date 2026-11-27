// ─── Climate pass 纯内核实现（Godot 无依赖）──────────────────────
//
// S3 搬迁体：下面 9 个 kernel 原位于 world_ext_climate.cpp（static 文件作用域），
// 现在是生产与 SHADOW worker 共用的唯一实现。搬迁是逐字的，不含任何算法改动；
// 任何数值行为变更必须单独提案，否则无法与 S2 分叉矩阵对齐。
//
// 不得 include godot_cpp。这一条约束就是“worker 可用”的全部含义。

#include "runtime_climate_passes.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <queue>
#include <utility>
#include <vector>

namespace pk {
namespace pk_async_climate {



// ─── Round 编排（9 pass 串联，生产 worker main 与 runtime worker 共用）──────
//
// S3：这段编排本身也必须共享。它决定 pass 顺序、mask 门控、尺寸守卫，以及每个
// pass 写完后哪些字段要刷回 in 供后续 pass 读（sync 路径靠 _flush_slot_to_map +
// refresh_slots_from_map 达到同样效果）。复制一份到 runtime worker 就等于重新引入
// “两套实现”——顺序或接力字段差一条，分叉矩阵就会把它报成算法分叉。
//
// in 是 in/out：逐 pass 的接力就写在它上面，所以调用方必须传自己的可变副本
// （生产是 worker 私有的 w_in_buf，runtime worker 是 kernel 的 scratch buf）。

// Stage breadcrumb。worker 线程上的访存违例会绕过 Godot 的 crash handler，日志里
// 看不到栈。开 PK_CLIMATE_STAGE_TRACE=1 后每个 stage 前写一行并 flush，崩溃后日志
// 最后一行就是出事的 stage。默认关，开关只读一次。
static bool pk_stage_trace_enabled() {
    static const bool on = [] {
        const char *v = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_STAGE_TRACE);
        return v != nullptr && v[0] == '1';
    }();
    return on;
}

static void pk_stage_trace(const char *stage, int day, int n_cells, uint32_t mask) {
    if (!pk_stage_trace_enabled()) return;
    std::fprintf(stderr, "[climate][stage-trace] day=%d mask=0x%X n=%d -> %s\n",
                 day, mask, n_cells, stage);
    std::fflush(stderr);
}

bool run_climate_round_passes(ClimateInputBuf &in,
                              const ClimateRoundStaticKnobs &knobs,
                              ClimateWorkBuf &work,
                              ClimateOutputBuf &out,
                              ClimateRoundPassTiming *timing) {
    using clock = std::chrono::steady_clock;
    bool ok = true;
    const int mask = in.scalars.passes_mask;

    // ─── pass_a（bit 0） ──────────────────────────────────────────
    pk_stage_trace("pass_a", -1, in.n_cells, mask);
    const auto pa0 = clock::now();
    if ((mask & 0x01) != 0 && (int)in.is_water.size() == in.n_cells) {
        // 输入完整时跑 pass_a pure kernel
        if (timing) timing->passes_ran |= 0x1;
        if (!_async_pass_a_kernel_pure(in, out)) {
            ok = false;
        }
        // Round 数据流：pass_a 写的字段刷新到 in，让后续 pass 读到 fresh 值。
        // sync 路径里 pass_a 通过 _flush_slot_to_map 把 16 个 slot 推回 MapData，
        // 然后下一 pass 入口的 refresh_slots_from_map 把 _slots 又拉到最新。
        // async 路径不走 MapData，但同 round 内的"上一 pass 写 → 下一 pass 读"
        // 必须用 in/out 同步实现。
        // 注：pass_a 是 round 第一个 pass，没有前序 pass 写过 in 字段；只刷新
        // pass_a 的输出回 in，让 pass_b / ocean_water / wind_air / transp 等读到。
        const int n_pa = in.n_cells;
        if (n_pa > 0) {
            auto cp_if_size = [n_pa](std::vector<float> &dst, const std::vector<float> &src) {
                if ((int)src.size() == n_pa) {
                    if ((int)dst.size() != n_pa) dst.resize(n_pa);
                    std::memcpy(dst.data(), src.data(), n_pa * sizeof(float));
                }
            };
            auto cp_if_size_u8 = [n_pa](std::vector<uint8_t> &dst, const std::vector<uint8_t> &src) {
                if ((int)src.size() == n_pa) {
                    if ((int)dst.size() != n_pa) dst.resize(n_pa);
                    std::memcpy(dst.data(), src.data(), n_pa);
                }
            };
            // pass_b 读这些字段：temp_baseline / moisture / snow_cover / insolation_dev
            // ocean_water 读 temp_baseline (作 baseline_arr)；其他 pass 间接读
            cp_if_size(in.moisture,         out.moisture);
            cp_if_size(in.temp_baseline,    out.temp_baseline);
            cp_if_size(in.insolation_dev,   out.insolation_dev);
            // sea_ice 的 solar gate 与融冰量读 in.insolation_now。漏掉这一行，它读到的
            // 是 capture 快照里的全零（该 slot 在 capture 时刻还没被这一天的 pass_a
            // 写过），于是 freeze_gate / solar_melt 整场按"永夜"走 —— 生产读的是
            // pass_a 刚算出的真值。
            cp_if_size(in.insolation_now,   out.insolation_now);
            cp_if_size(in.thermal_energy,   out.thermal_energy);
            cp_if_size(in.snowpack,         out.snowpack);
            cp_if_size(in.temp_30d,         out.temp_30d);
            cp_if_size(in.temp_365d,        out.temp_365d);
            cp_if_size_u8(in.ema_initialized, out.ema_initialized);
            // ocean / local anomaly 被 pass_a 清 0；同步给 pass_b/ocean_*
            cp_if_size(in.ocean_thermal_anomaly, out.ocean_thermal_anomaly);
            cp_if_size(in.local_thermal_anomaly, out.local_thermal_anomaly);
        }
    }
    const auto pa1 = clock::now();
    if (timing) timing->pass_us[0] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            pa1 - pa0).count();
    if (timing && (mask & 0x1) != 0 &&
        (timing->passes_ran & 0x1) == 0) {
        timing->passes_starved |= 0x1;
    }

    // ─── pass_b（bit 1） ──────────────────────────────────────────
    pk_stage_trace("pass_b", -1, in.n_cells, mask);
    const auto pb0 = clock::now();
    if ((mask & 0x02) != 0
            && (int)in.is_water.size()       == in.n_cells
            && (int)in.landform.size()       == in.n_cells
            && (int)in.vegetation.size()     == in.n_cells
            && (int)in.snowpack.size()       == in.n_cells
            && (int)in.elevation.size()      == in.n_cells
            && (int)in.lat_norm.size()       == in.n_cells
            && (int)in.pos_x.size()          == in.n_cells
            && (int)in.pos_y.size()          == in.n_cells
            && (int)in.insolation_dev.size() == in.n_cells
            && (int)in.temp.size()           == in.n_cells
            && (int)in.moisture.size()       == in.n_cells
            && (int)in.local_thermal_anomaly.size() == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells
            && (int)knobs.foliage_table.size() > 0) {
        if (timing) timing->passes_ran |= 0x2;
        if (!_async_pass_b_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：pass_b 写 moisture（覆盖 pass_a）+ local_thermal_anomaly。
        // 同步给 ocean_water/land 和 wind_air/surface 等后续 pass。
        const int n_pb = in.n_cells;
        if (n_pb > 0) {
            if (((int)out.moisture.size() == n_pb)
                    && (int) in.moisture.size() == n_pb) {
                std::memcpy(in.moisture.data(),
                            out.moisture.data(), n_pb * sizeof(float));
            }
            if (((int)out.local_thermal_anomaly.size() == n_pb)
                    && (int) in.local_thermal_anomaly.size() == n_pb) {
                std::memcpy(in.local_thermal_anomaly.data(),
                            out.local_thermal_anomaly.data(), n_pb * sizeof(float));
            }
        }
    }
    const auto pb1 = clock::now();
    if (timing) timing->pass_us[1] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            pb1 - pb0).count();
    if (timing && (mask & 0x2) != 0 &&
        (timing->passes_ran & 0x2) == 0) {
        timing->passes_starved |= 0x2;
    }

    // ─── ocean_water（bit 2） ─────────────────────────────────────
    pk_stage_trace("ocean_water", -1, in.n_cells, mask);
    const auto ow0 = clock::now();
    if ((mask & 0x04) != 0
            && (int)in.is_water.size()        == in.n_cells
            && (int)in.pos_x.size()           == in.n_cells
            && (int)in.pos_y.size()           == in.n_cells
            && (int)in.ocean_current_x.size() == in.n_cells
            && (int)in.ocean_current_y.size() == in.n_cells
            && (int)in.temp.size()            == in.n_cells
            && (int)in.temp_baseline_year.size() == in.n_cells
            && (int)in.ocean_thermal_anomaly.size() == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells) {
        if (timing) timing->passes_ran |= 0x4;
        if (!_async_ocean_water_kernel_pure(in, knobs,
                                            work, out)) {
            ok = false;
        }
        // Round 数据流：ocean_water 写 ocean_thermal_anomaly (water cells)。
        // ocean_land 通过 work.ocean_tta_inout 读 water cells fresh anomaly，
        // ocean_thermal_anomaly slot 也要同步给 wind_surface 做合成。
        const int n_ow = in.n_cells;
        if ((n_ow > 0 && (int)out.ocean_thermal_anomaly.size() == n_ow)
                && (int) in.ocean_thermal_anomaly.size() == n_ow) {
            std::memcpy(in.ocean_thermal_anomaly.data(),
                        out.ocean_thermal_anomaly.data(), n_ow * sizeof(float));
        }
    }
    const auto ow1 = clock::now();
    if (timing) timing->pass_us[2] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            ow1 - ow0).count();
    if (timing && (mask & 0x4) != 0 &&
        (timing->passes_ran & 0x4) == 0) {
        timing->passes_starved |= 0x4;
    }

    // ─── ocean_land（bit 3） — 依赖 ocean_water 写完 work.ocean_tta_inout
    pk_stage_trace("ocean_land", -1, in.n_cells, mask);
    const auto ol0 = clock::now();
    if ((mask & 0x08) != 0
            && (int)in.is_water.size()        == in.n_cells
            && (int)in.pos_x.size()           == in.n_cells
            && (int)in.pos_y.size()           == in.n_cells
            && (int)in.ocean_current_x.size() == in.n_cells
            && (int)in.ocean_current_y.size() == in.n_cells) {
        // 若 ocean_water 没跑，ocean_tta_inout 还是空——单跑 ocean_land 时
        // 用 in.temp_transport_anomaly 初始化它。
        if ((int)work.ocean_tta_inout.size() != in.n_cells
                && (int)in.temp_transport_anomaly.size() == in.n_cells) {
            work.ocean_tta_inout.resize(in.n_cells);
            std::memcpy(work.ocean_tta_inout.data(),
                        in.temp_transport_anomaly.data(),
                        in.n_cells * sizeof(float));
        }
        if (timing) timing->passes_ran |= 0x8;
        if (!_async_ocean_land_kernel_pure(in, knobs,
                                           work, out)) {
            ok = false;
        }
        // Round 数据流：ocean_land 累加 ocean_thermal_anomaly (land cells)。
        // wind_surface 读它做合成。
        const int n_ol = in.n_cells;
        if ((n_ol > 0 && (int)out.ocean_thermal_anomaly.size() == n_ol)
                && (int) in.ocean_thermal_anomaly.size() == n_ol) {
            std::memcpy(in.ocean_thermal_anomaly.data(),
                        out.ocean_thermal_anomaly.data(), n_ol * sizeof(float));
        }
    }
    const auto ol1 = clock::now();
    if (timing) timing->pass_us[3] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            ol1 - ol0).count();
    if (timing && (mask & 0x8) != 0 &&
        (timing->passes_ran & 0x8) == 0) {
        timing->passes_starved |= 0x8;
    }

    // ─── wind_air / wind_surface / sea_ice 仍是 stub
    // TTA 在 round 内只活在 work.ocean_tta_inout 里（ocean_water 写水格、ocean_land
    // 写陆格），而 wind_surface 与 sea_ice 读的是 in.temp_transport_anomaly。少了这次
    // 回写，它们读到的是 kick 时刻的初值 —— 生产那两个 pass 跑在 ocean 之后，读的是
    // 刚累加完的值。与 insolation_now 是同一类漏接。
    if ((int) work.ocean_tta_inout.size() == in.n_cells &&
        (int) in.temp_transport_anomaly.size() == in.n_cells && in.n_cells > 0) {
        std::memcpy(in.temp_transport_anomaly.data(),
                    work.ocean_tta_inout.data(),
                    size_t(in.n_cells) * sizeof(float));
    }

    // 把生产 wind_surface 真正读到的 oanom 注回来（见 WindSurfaceInput 注释）。
    //
    // 位置必须在 ocean_land 之后、wind_air 之前，不能提到 pass_a 后面：
    //   • ocean_water / ocean_land 是**累加** oanom 的。提前注入等于让它们在生产的
    //     成品值上再累一遍 —— 实测 wind_surface 读到的 oanom 正好是生产的两倍。
    //   • 生产的 pass_b 跑在 ocean 之前，读到的是 pass_a 刚清零的 oanom。提前注入
    //     会让 worker 的 pass_b 读到非零值。
    // in 与 out 都要写：wind_surface 取的是 choose_field(out, in)，只写一边会被另一
    // 边的值盖掉。
    if ((int) in.production_ocean_anomaly.size() == in.n_cells && in.n_cells > 0) {
        const size_t bytes = size_t(in.n_cells) * sizeof(float);
        if ((int) in.ocean_thermal_anomaly.size() == in.n_cells) {
            std::memcpy(in.ocean_thermal_anomaly.data(),
                        in.production_ocean_anomaly.data(), bytes);
        }
        if ((int) out.ocean_thermal_anomaly.size() == in.n_cells) {
            std::memcpy(out.ocean_thermal_anomaly.data(),
                        in.production_ocean_anomaly.data(), bytes);
        }
    }

    pk_stage_trace("wind_air", -1, in.n_cells, mask);
    // ─── wind_air（bit 4） ────────────────────────────────────────
    const auto wa0 = clock::now();
    if ((mask & 0x10) != 0
            && (int)in.wind_x.size()  == in.n_cells
            && (int)in.wind_y.size()  == in.n_cells
            && (int)in.wind_speed.size() == in.n_cells
            && (int)in.pos_x.size()   == in.n_cells
            && (int)in.pos_y.size()   == in.n_cells
            && (int)in.temp.size()    == in.n_cells
            && (int)in.temp_baseline_year.size() == in.n_cells) {
        if (timing) timing->passes_ran |= 0x10;
        if (!_async_wind_air_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：wind_air 写 air_mass_temp_anomaly。
        // wind_surface 读它（作为 AIN snapshot）做加权平均。
        const int n_wa = in.n_cells;
        if ((n_wa > 0 && (int)out.air_mass_temp_anomaly.size() == n_wa)
                && (int) in.air_mass_temp_anomaly.size() == n_wa) {
            std::memcpy(in.air_mass_temp_anomaly.data(),
                        out.air_mass_temp_anomaly.data(), n_wa * sizeof(float));
        }
    }
    const auto wa1 = clock::now();
    if (timing) timing->pass_us[4] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            wa1 - wa0).count();
    if (timing && (mask & 0x10) != 0 &&
        (timing->passes_ran & 0x10) == 0) {
        timing->passes_starved |= 0x10;
    }

    // ─── wind_surface（bit 5） — 依赖 wind_air / pass_a / pass_b / ocean_*
    pk_stage_trace("wind_surface", -1, in.n_cells, mask);
    const auto ws0 = clock::now();
    if ((mask & 0x20) != 0
            && (int)in.wind_x.size()  == in.n_cells
            && (int)in.wind_y.size()  == in.n_cells
            && (int)in.wind_speed.size() == in.n_cells
            && (int)in.pos_x.size()   == in.n_cells
            && (int)in.pos_y.size()   == in.n_cells) {
        if (timing) timing->passes_ran |= 0x20;
        if (!_async_wind_surface_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：wind_surface 写 cell_temp（合成）+ overwrite air_anom。
        // sea_ice 期望读 climate/ocean-adjusted T —— round 模式下这就是 wind_surface
        // 输出的 cell_temp，同步给 in.cell_temperature_arr（覆盖 kick 传入的旧值）。
        const int n_ws = in.n_cells;
        if (n_ws > 0) {
            if ((int)out.temp.size() == n_ws) {
                if ((int)in.cell_temperature_arr.size() != n_ws) {
                    in.cell_temperature_arr.resize(n_ws);
                }
                std::memcpy(in.cell_temperature_arr.data(),
                            out.temp.data(), n_ws * sizeof(float));
            }
            if (((int)out.air_mass_temp_anomaly.size() == n_ws)
                    && (int) in.air_mass_temp_anomaly.size() == n_ws) {
                std::memcpy(in.air_mass_temp_anomaly.data(),
                            out.air_mass_temp_anomaly.data(), n_ws * sizeof(float));
            }
        }
    }
    const auto ws1 = clock::now();
    if (timing) timing->pass_us[5] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            ws1 - ws0).count();
    if (timing && (mask & 0x20) != 0 &&
        (timing->passes_ran & 0x20) == 0) {
        timing->passes_starved |= 0x20;
    }

    // sea_ice 仍是 stub（Stage 2 余下工作）
    // ─── sea_ice（bit 6） ─────────────────────────────────────────
    pk_stage_trace("sea_ice", -1, in.n_cells, mask);
    const auto si0 = clock::now();
    if ((mask & 0x40) != 0
            && (int)in.terrain.size()              == in.n_cells
            && (int)in.base_terrain.size()         == in.n_cells
            && (int)in.sea_ice_frac_inout.size()   == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells
            && (int)in.upwelling_strength.size()   == in.n_cells
            && (int)in.insolation_now.size()       == in.n_cells
            && (int)in.cell_temperature_arr.size() == in.n_cells
            && (int)in.water_terrain_ids.size()    > 0) {
        if (timing) timing->passes_ran |= 0x40;
        if (!_async_sea_ice_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：sea_ice 写 sea_ice_frac + 翻转 terrain。transp 不依赖
        // 它们；但 in.sea_ice_frac_inout / in.terrain 同步以便后续诊断 / round
        // 重复 kick 时拿到最新值（虽然单 round 不会重复跑同一 pass）。
        const int n_si = in.n_cells;
        if (n_si > 0) {
            if (((int)out.sea_ice_frac.size() == n_si)
                    && (int) in.sea_ice_frac_inout.size() == n_si) {
                std::memcpy(in.sea_ice_frac_inout.data(),
                            out.sea_ice_frac.data(), n_si * sizeof(float));
            }
            if (((int)out.terrain.size() == n_si)
                    && (int) in.terrain.size() == n_si) {
                std::memcpy(in.terrain.data(),
                            out.terrain.data(), n_si);
            }
        }
    }
    const auto si1 = clock::now();
    if (timing) timing->pass_us[6] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            si1 - si0).count();
    if (timing && (mask & 0x40) != 0 &&
        (timing->passes_ran & 0x40) == 0) {
        timing->passes_starved |= 0x40;
    }

    // ─── transp（bit 7） ──────────────────────────────────────────
    pk_stage_trace("transp", -1, in.n_cells, mask);
    const auto tr0 = clock::now();
    if ((mask & 0x80) != 0
            && (int)in.landform.size()   == in.n_cells
            && (int)in.vegetation.size() == in.n_cells
            && (int)in.moisture.size()   == in.n_cells) {
        if (timing) timing->passes_ran |= 0x80;
        if (!_async_transp_kernel_pure(in, knobs,
                                       work, out)) {
            ok = false;
        }
    }
    const auto tr1 = clock::now();
    if (timing) timing->pass_us[7] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            tr1 - tr0).count();
    if (timing && (mask & 0x80) != 0 &&
        (timing->passes_ran & 0x80) == 0) {
        timing->passes_starved |= 0x80;
    }

    // ─── finalizer（bit 8，Stage 9 2026-06-16） ──────────────────────
    pk_stage_trace("finalizer", -1, in.n_cells, mask);
    // 在 round 末尾跑一次：clamp temp/TTA、统计 Δ percentile、thermal init、
    // sea_ice_delta_max、precip_p95。等价 GDScript _apply_daily_climate_finalizer。
    const auto fi0 = clock::now();
    if ((mask & 0x100) != 0
            && (int)in.temp.size() == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells
            && (int)in.thermal_energy.size() == in.n_cells) {
        // out.temp 已被 wind_surface 写入（mask bit 5 启用时）；finalizer
        // 在它之上 clamp。若 wind_surface 没写过（mask bit 5 关闭），kernel
        // 内部用 in.temp 兜底初始化 out.temp。
        if (timing) timing->passes_ran |= 0x100;
        if (!_async_finalizer_kernel_pure(in, out)) {
            ok = false;
        }
    }
    const auto fi1 = clock::now();
    if (timing) timing->pass_us[8] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            fi1 - fi0).count();
    if (timing && (mask & 0x100) != 0 &&
        (timing->passes_ran & 0x100) == 0) {
        timing->passes_starved |= 0x100;
    }
    out.n_cells = in.n_cells;
    return ok;
}



} // namespace pk_async_climate
} // namespace pk
