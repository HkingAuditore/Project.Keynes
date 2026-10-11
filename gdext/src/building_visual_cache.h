#pragma once

#include <memory>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace pk {

struct BuildingVisualCacheState;

// Per-cell settlement layout cache for BuildingVisualLayer. The main thread
// submits only cells whose last-seen building row changed; one dedicated
// worker plans them off-thread (no Godot API on the worker) and stores the
// encoded instances per cell. Chunk upload is a concatenation of cached cells.
class NativeBuildingVisualCache : public godot::RefCounted {
    GDCLASS(NativeBuildingVisualCache, godot::RefCounted);

public:
    NativeBuildingVisualCache();
    ~NativeBuildingVisualCache() override;

    godot::Dictionary configure(const godot::Dictionary &config);
    godot::Dictionary submit_cells(const godot::Dictionary &rows);
    void set_quality(int quality);
    godot::PackedInt32Array take_ready_chunks();
    godot::PackedInt32Array chunks_in_rect(const godot::Rect2 &rect,
            const godot::Vector2 &center, int limit) const;
    godot::Dictionary build_chunk(int chunk_id, int instance_cap) const;
    bool wait_idle(int timeout_msec);
    int pending_cells() const;
    godot::Dictionary diagnostics() const;
    void shutdown();

protected:
    static void _bind_methods();

private:
    std::unique_ptr<BuildingVisualCacheState> _state;
};

} // namespace pk
