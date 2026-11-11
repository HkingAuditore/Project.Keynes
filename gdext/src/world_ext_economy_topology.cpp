#include "world_ext.h"
#include "economy_api.h"

namespace pk {
using namespace godot;
namespace {
NativeEconomyRuntime *runtime_from(void *opaque) {
    return static_cast<NativeEconomyRuntime *>(opaque);
}
Dictionary unavailable() {
    Dictionary result;
    result["ok"] = false;
    result["reason"] = "economy_not_configured";
    return result;
}
}

Dictionary DCWorldExt::capture_economy_trade_topology(
        const PackedInt32Array &neighbor_indices, const PackedByteArray &terrain,
        const PackedByteArray &trade_passable_lut,
        const PackedInt32Array &trade_move_cost_lut, int64_t generation,
        const PackedByteArray &landform, const PackedByteArray &has_river) {
    if (_economy_runtime == nullptr) return unavailable();
    Dictionary out;
    if (neighbor_indices.size() != terrain.size() * 6 ||
        trade_passable_lut.size() != 256 || trade_move_cost_lut.size() != 256) {
        out["ok"] = false;
        out["reason"] = "trade_topology_column_size_mismatch";
        return out;
    }
    std::string error;
    std::vector<uint8_t> empty_canal(static_cast<size_t>(terrain.size()), 0);
    std::vector<float> empty_water(static_cast<size_t>(terrain.size()), 0.0f);
    const uint8_t *landform_ptr = landform.size() == terrain.size() ? landform.ptr() : nullptr;
    const uint8_t *river_ptr = has_river.size() == terrain.size() ? has_river.ptr() : nullptr;
    const bool ok = economy_api::capture_trade_topology(*runtime_from(_economy_runtime),
        neighbor_indices.ptr(), terrain.ptr(), empty_canal.data(), empty_water.data(),
        trade_passable_lut.ptr(),
        trade_move_cost_lut.ptr(), terrain.size(), static_cast<uint64_t>(generation),
        error, landform_ptr, river_ptr);
    // A restored executor may serve the cache while its next day owns the
    // boundary lock. Publish topology readiness before handing it execution.
    if (ok) _economy_read_report_cache = economy_api::detail_report(*runtime_from(_economy_runtime));
    out["ok"] = ok;
    if (!ok) out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::capture_economy_trade_visibility(
        const PackedByteArray &visible, bool fog_solved) {
    if (_economy_runtime == nullptr) return unavailable();
    Dictionary out;
    std::string error;
    const bool ok = economy_api::capture_trade_visibility(*runtime_from(_economy_runtime),
        visible.ptr(), visible.size(), fog_solved, false, error);
    out["ok"] = ok;
    if (!ok) out["reason"] = String(error.c_str());
    return out;
}

} // namespace pk
