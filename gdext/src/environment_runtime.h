#pragma once

#include <cstdint>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>

namespace pk {

class EnvironmentRuntime : public godot::RefCounted {
    GDCLASS(EnvironmentRuntime, godot::RefCounted);

public:
    EnvironmentRuntime();
    ~EnvironmentRuntime() override;

    void initialize(int cell_count, int pixel_count);
    void initialize_with_sizes(int cell_count, godot::Vector2i pixel_size);
    void rebuild(int cell_count, int pixel_count, bool topology_changed = true);
    void rebuild_for_map(int width, int height, godot::Vector2i pixel_size);
    void clear();

    bool is_initialized() const { return _initialized; }
    int get_cell_count() const { return _cell_count; }
    int get_pixel_count() const { return _pixel_count; }
    godot::Vector2i get_pixel_size() const { return _pixel_size; }
    int get_snapshot_version() const { return _snapshot_version; }
    int get_rebuild_generation() const { return _rebuild_generation; }

    void bind_core_buffers(godot::PackedFloat32Array elevation,
                           godot::PackedFloat32Array temperature,
                           godot::PackedFloat32Array moisture,
                           godot::PackedFloat32Array pressure,
                           godot::PackedFloat32Array wind_x,
                           godot::PackedFloat32Array wind_y,
                           godot::PackedFloat32Array ocean_x,
                           godot::PackedFloat32Array ocean_y);
    void bind_weather_buffers(godot::PackedFloat32Array vapor,
                              godot::PackedFloat32Array cloud,
                              godot::PackedFloat32Array precip);

    void build_topology_from_arrays(godot::PackedInt32Array neighbors,
                                    godot::PackedByteArray is_water,
                                    godot::PackedByteArray terrain_mask,
                                    godot::PackedInt32Array pixel_to_cell = godot::PackedInt32Array());
    void mark_cells_dirty(godot::PackedInt32Array indices,
                          const godot::String &reason = godot::String());
    void mark_region_dirty(int start_idx, int end_idx,
                           const godot::String &reason = godot::String());

    void begin_round(const godot::String &round_name = godot::String("environment"));
    godot::Dictionary step_budgeted(double budget_ms = 0.5,
                                    int max_cells = 0,
                                    int max_pixels = 0,
                                    int max_indices = 0);
    void begin_ocean_round(bool include_raster = true);
    godot::Dictionary step_ocean_budgeted(double budget_ms = 0.75,
                                          int max_cells = 0,
                                          int max_pixels = 0,
                                          int max_indices = 0);
    godot::PackedInt32Array consume_ocean_dirty_tiles();
    void begin_weather_round(bool use_active_list = true);
    godot::Dictionary step_weather_budgeted(double budget_ms = 0.55,
                                            int max_cells = 0,
                                            int max_pixels = 0,
                                            int max_indices = 0);
    void begin_climate_round(bool use_dirty_list = true);
    godot::Dictionary step_climate_budgeted(double budget_ms = 0.75,
                                            int max_cells = 0,
                                            int max_pixels = 0,
                                            int max_indices = 0);
    bool is_round_done() const;
    void reset_stage_progress();

    void publish_snapshot();
    void mark_all_dirty();
    void clear_dirty();

    godot::Dictionary status() const;
    godot::Dictionary buffer_summary() const;
    godot::Dictionary snapshot_summary() const;
    godot::Dictionary topology_summary() const;
    godot::Dictionary progress_summary() const;
    godot::Dictionary export_runtime_state() const;
    godot::Dictionary restore_runtime_state(const godot::Dictionary &state);

protected:
    static void _bind_methods();

private:
    struct StageState {
        godot::String name;
        godot::String substage;
        int total = 0;
        int cursor = 0;
        int kind = 0; // 0=cell, 1=pixel, 2=index/barrier-like generic work
    };

    void _allocate_buffers(int cell_count, int pixel_count);
    void _reset_runtime_state(bool topology_changed);
    static void _resize_f32(std::vector<float> &v, int n, float fill = 0.0f);
    static void _resize_i32(std::vector<int32_t> &v, int n, int32_t fill = -1);
    static void _resize_u8(std::vector<uint8_t> &v, int n, uint8_t fill = 0);
    void _append_unique_dirty(int idx);
    void _append_unique_weather_active(int idx);
    bool _is_water_idx(int idx) const;
    void _build_default_stages();
    void _build_ocean_stages(bool include_raster);
    void _build_weather_stages(bool use_active_list);
    void _build_climate_stages(bool use_dirty_list);
    StageState *_current_stage();
    const StageState *_current_stage() const;

    bool _initialized = false;
    int _cell_count = 0;
    int _pixel_count = 0;
    godot::Vector2i _pixel_size;
    int _snapshot_version = 0;
    int _rebuild_generation = 0;

    // Stable cell-level SoA owned by the native runtime. GDScript can still
    // bind current map arrays during migration; these vectors are the future
    // authoritative storage once hot passes stop returning PackedArray copies.
    std::vector<float> _elevation;
    std::vector<float> _temperature;
    std::vector<float> _moisture;
    std::vector<float> _pressure;
    std::vector<float> _wind_x;
    std::vector<float> _wind_y;
    std::vector<float> _wind_speed;
    std::vector<float> _ocean_x;
    std::vector<float> _ocean_y;
    std::vector<float> _ocean_speed;

    // Persistent weather ping-pong and work buffers.
    std::vector<float> _weather_vapor_a;
    std::vector<float> _weather_vapor_b;
    std::vector<float> _weather_cloud_a;
    std::vector<float> _weather_cloud_b;
    std::vector<float> _weather_precip_a;
    std::vector<float> _weather_precip_b;

    // Dirty/active sets and fixed topology caches. Detailed population lands
    // in the next task; this skeleton owns lifetime and capacity now.
    std::vector<uint8_t> _climate_dirty_mask;
    std::vector<uint8_t> _weather_dirty_mask;
    std::vector<uint8_t> _terrain_mask;
    std::vector<int32_t> _active_weather_indices;
    std::vector<int32_t> _dirty_climate_indices;
    std::vector<int32_t> _water_indices;
    std::vector<int32_t> _coastal_indices;
    std::vector<int32_t> _neighbor_indices;
    std::vector<int32_t> _pixel_to_cell;
    std::vector<int32_t> _ocean_dirty_tiles;

    bool _topology_valid = false;
    bool _all_dirty = true;

    bool _ocean_round_active = false;
    bool _ocean_include_raster = true;
    int _ocean_dirty_tile_size = 64;

    bool _weather_round_active = false;
    bool _weather_use_active_list = true;
    bool _weather_pingpong_a_is_prev = true;
    int _weather_snapshot_version = 0;

    bool _climate_round_active = false;
    bool _climate_use_dirty_list = true;
    int _climate_snapshot_version = 0;

    godot::String _round_name;
    std::vector<StageState> _stages;
    int _stage_index = 0;
    bool _round_active = false;
    int _last_processed = 0;
    double _last_elapsed_ms = 0.0;
};

} // namespace pk
