// Every C++ hot pass writes SoA slots via ptrw(). The first ptrw() after
// bind_map_data (or after a prior flush) triggers a CoW detach — C++ gets
// a private buffer, GDScript's map.*_arr still references the old one.
//
// _flush_slot_to_map: reverse-lookup the property name via BIND_TABLE and
//   push the C++ buffer back to GDScript via obj->set(). This is an O(1)
//   Variant reference swap, not a memcpy.
//
// flush_slots_to_map / refresh_slots_from_map: bulk versions that iterate
//   all bound slots.

static bool pk_slot_affects_visual_dirty(const godot::StringName &slot_name) {
    const godot::String s(slot_name);
    return s.begins_with("cell_temp") ||
           s.begins_with("cell_moisture") ||
           s.begins_with("cell_base_moisture") ||
           s.begins_with("cell_snow") ||
           s.begins_with("cell_sea_ice") ||
           s.begins_with("cell_terrain") ||
           s.begins_with("cell_landform") ||
           s.begins_with("cell_vegetation") ||
           s.begins_with("cell_cover") ||
           s == godot::String("cell_canal_edge_mask") ||
           s.begins_with("cell_weather") ||
           s.begins_with("cell_ocean_thermal") ||
           s.begins_with("cell_local_thermal") ||
           s == godot::String("cell_thermal_energy");
}

void DCWorldExt::bind_dirty_world(godot::Object *dirty_world) {
    _dirty_world = dirty_world;
}

static int pk_visual_dirty_dense_threshold(int cell_count) {
    if (cell_count <= 0) return 0;
    const int ratio_threshold = (cell_count + 3) / 4;
    return std::min(cell_count, std::max(64, ratio_threshold));
}

int DCWorldExt::_bind_index_for_slot(int comp_id) {
    if (comp_id < 0 || comp_id >= _slots.size()) return -1;
    if (int(_slot_bind_index_cache.size()) <= comp_id)
        _slot_bind_index_cache.resize(size_t(_slots.size()), int16_t{-2});
    int16_t &cached = _slot_bind_index_cache[size_t(comp_id)];
    if (cached != -2) return int(cached);
    const StringName &slot_name = _slots[comp_id].name;
    cached = -1;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        if (slot_name == StringName(BIND_TABLE[i].slot_name)) {
            cached = int16_t(i);
            break;
        }
    }
    return int(cached);
}

const char *DCWorldExt::_slot_name_for_property(const char *property_name) {
    if (property_name == nullptr || property_name[0] == '\0') return nullptr;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        if (std::strcmp(property_name, BIND_TABLE[i].property_name) == 0)
            return BIND_TABLE[i].slot_name;
    }
    return nullptr;
}

bool DCWorldExt::_slot_is_visual_dirty(int comp_id) {
    if (comp_id < 0 || comp_id >= _slots.size()) return false;
    if (int(_slot_visual_dirty_cache.size()) <= comp_id)
        _slot_visual_dirty_cache.resize(size_t(_slots.size()), uint8_t{0});
    uint8_t &cached = _slot_visual_dirty_cache[size_t(comp_id)];
    if (cached == 0)
        cached = pk_slot_affects_visual_dirty(_slots[comp_id].name) ? uint8_t{2} : uint8_t{1};
    return cached == 2;
}

void DCWorldExt::_flush_slot_to_map(int comp_id, bool notify_resources) {
    if (!_map_data || comp_id < 0 || comp_id >= _slots.size()) return;
    const Slot &s = _slots[comp_id];
    {
        const int bind_index = _bind_index_for_slot(comp_id);
        if (bind_index >= 0) {
            const int i = bind_index;
            const StringName prop_name(BIND_TABLE[i].property_name);
            const bool visual_slot = _slot_is_visual_dirty(comp_id);
            // 非视觉 slot 不做 diff，previous 也就无人消费。它是一次
            // Object::get + Variant 构造 + PackedArray 引用计数往返。
            const Variant previous = visual_slot ? _map_data->get(prop_name) : Variant();
            bool any_visual_dirty = false;
            int cell_limit = _native_world_cell_count;
            if (cell_limit <= 0) {
                switch (s.dtype) {
                    case SlotDType::F32: cell_limit = s.arr_f32.size(); break;
                    case SlotDType::I32: cell_limit = s.arr_i32.size(); break;
                    case SlotDType::U8:  cell_limit = s.arr_u8.size(); break;
                }
            }
            if (visual_slot && cell_limit > 0 &&
                    _pending_visual_dirty_mask.size() != cell_limit) {
                _pending_visual_dirty_mask.resize(cell_limit);
            }
            auto mark_changed = [&](int idx) {
                if (!visual_slot || _pending_visual_dirty_dense ||
                        idx < 0 || idx >= cell_limit) return;
                if (_pending_visual_dirty_mask[idx] != 0) {
                    any_visual_dirty = true;
                    return;
                }
                _pending_visual_dirty_mask.set(idx, uint8_t(1));
                ++_pending_visual_dirty_count;
                any_visual_dirty = true;
                const int dense_threshold = pk_visual_dirty_dense_threshold(cell_limit);
                if (dense_threshold > 0 && _pending_visual_dirty_count >= dense_threshold) {
                    _pending_visual_dirty_dense = true;
                }
            };
            switch (s.dtype) {
                case SlotDType::F32: {
                    if (visual_slot && previous.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
                        const PackedFloat32Array old_values = previous;
                        const int n = std::min(cell_limit,
                                std::min(int(old_values.size()), int(s.arr_f32.size())));
                        for (int idx = 0; idx < n && !_pending_visual_dirty_dense; ++idx) {
                            if (old_values[idx] != s.arr_f32[idx]) mark_changed(idx);
                        }
                        for (int idx = n; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    } else if (visual_slot) {
                        for (int idx = 0; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    }
                    _map_data->set(prop_name, s.arr_f32);
                    if (std::strcmp(BIND_TABLE[i].property_name, "elevation_arr") == 0)
                        pk::publish_map_overlay_elevation(_map_data);
                    break;
                }
                case SlotDType::I32: {
                    if (visual_slot && previous.get_type() == Variant::PACKED_INT32_ARRAY) {
                        const PackedInt32Array old_values = previous;
                        const int n = std::min(cell_limit,
                                std::min(int(old_values.size()), int(s.arr_i32.size())));
                        for (int idx = 0; idx < n && !_pending_visual_dirty_dense; ++idx) {
                            if (old_values[idx] != s.arr_i32[idx]) mark_changed(idx);
                        }
                        for (int idx = n; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    } else if (visual_slot) {
                        for (int idx = 0; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    }
                    _map_data->set(prop_name, s.arr_i32);
                    break;
                }
                case SlotDType::U8: {
                    if (visual_slot && previous.get_type() == Variant::PACKED_BYTE_ARRAY) {
                        const PackedByteArray old_values = previous;
                        const int n = std::min(cell_limit,
                                std::min(int(old_values.size()), int(s.arr_u8.size())));
                        for (int idx = 0; idx < n && !_pending_visual_dirty_dense; ++idx) {
                            if (old_values[idx] != s.arr_u8[idx]) mark_changed(idx);
                        }
                        for (int idx = n; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    } else if (visual_slot) {
                        for (int idx = 0; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    }
                    _map_data->set(prop_name, s.arr_u8);
                    break;
                }
            }
            if (notify_resources) pk::notify_resource_visual_publication(_map_data, BIND_TABLE[i].property_name);
            if (any_visual_dirty || _pending_visual_dirty_dense) {
                _pending_mark_dirty_all = true;
                _native_dirty_report["flush_dirty_reason"] =
                        String("visual_slot_diff:") + String(s.name);
                _native_dirty_report["flush_dirty_slot"] = String(s.name);
                _native_dirty_report["flush_dirty_all_pending"] = true;
            } else if (!visual_slot) {
                _native_dirty_report["flush_dirty_filtered_count"] =
                        int(_native_dirty_report.get("flush_dirty_filtered_count", 0)) + 1;
                _native_dirty_report["flush_dirty_last_filtered_slot"] = String(s.name);
            }
            return;
        }
    }
}

void DCWorldExt::flush_pending_mark_dirty_all() {
    if (_pending_mark_dirty_all && _dirty_world) {
        if (_pending_visual_dirty_dense) {
            _dirty_world->call(StringName("mark_dirty_all"));
        } else if (_pending_visual_dirty_count > 0) {
            PackedInt32Array dirty_indices;
            dirty_indices.resize(_pending_visual_dirty_count);
            int write = 0;
            for (int i = 0; i < _pending_visual_dirty_mask.size(); ++i) {
                if (_pending_visual_dirty_mask[i] != 0) dirty_indices.set(write++, i);
            }
            if (_dirty_world->has_method(StringName("mark_dirty_indexed"))) {
                _dirty_world->call(StringName("mark_dirty_indexed"), dirty_indices);
            } else {
                _dirty_world->call(StringName("mark_dirty_all"));
            }
        }
        _native_dirty_report["flush_dirty_indexed_count"] =
                _pending_visual_dirty_dense ? 0 : _pending_visual_dirty_count;
        _native_dirty_report["flush_dirty_observed_count"] = _pending_visual_dirty_count;
        _native_dirty_report["flush_dirty_dense_fallback"] = _pending_visual_dirty_dense;
        _native_dirty_report["flush_dirty_dense_threshold"] =
                pk_visual_dirty_dense_threshold(_pending_visual_dirty_mask.size());
        _native_dirty_report["flush_dirty_all_emitted"] = true;
    }
    _pending_mark_dirty_all = false;
    _pending_visual_dirty_mask = PackedByteArray();
    _pending_visual_dirty_count = 0;
    _pending_visual_dirty_dense = false;
    _native_dirty_report["flush_dirty_all_pending"] = false;
}

void DCWorldExt::flush_slots_to_map() {
    ++_runtime_graph_full_flush_count;
    if (!_map_data) return;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        const StringName slot_name(BIND_TABLE[i].slot_name);
        const int sid = component_id(slot_name);
        if (sid < 0 || sid >= _slots.size()) continue;
        _flush_slot_to_map(sid);
    }
    _economy_resource_slot_resident.clear();
    flush_pending_mark_dirty_all();
}

void DCWorldExt::flush_slots_to_map_keys(const PackedStringArray &slot_names) {
    if (!_map_data) return;
    for (int i = 0; i < slot_names.size(); ++i) {
        const int sid = component_id(StringName(slot_names[i]));
        if (sid >= 0) {
            _flush_slot_to_map(sid);
            if (sid < static_cast<int>(_economy_resource_slot_resident.size()))
                _economy_resource_slot_resident[static_cast<size_t>(sid)] = 0;
        }
    }
}

void DCWorldExt::refresh_slots_from_map() {
    SimTraceWriteGuard sim_trace_guard{this, "refresh_slots_from_map"};
    if (!_map_data) return;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        const StringName slot_name(BIND_TABLE[i].slot_name);
        // Preserve the in-flight native moisture value while visible MapData
        // remains frozen at the previous completed round.
        if (_native_daily_visual_commit_pending &&
            slot_name == StringName("cell_moisture")) {
            continue;
        }
        const int sid = component_id(slot_name);
        if (sid < 0 || sid >= _slots.size()) continue;
        if (sid < static_cast<int>(_economy_resource_slot_resident.size()) &&
            _economy_resource_slot_resident[static_cast<size_t>(sid)] != 0) {
            continue;
        }
        Slot &s = _slots.write[sid];
        const StringName prop_name(BIND_TABLE[i].property_name);
        Variant v = _map_data->get(prop_name);
        switch (s.dtype) {
            case SlotDType::F32: s.arr_f32 = v; break;
            case SlotDType::I32: s.arr_i32 = v; break;
            case SlotDType::U8:  s.arr_u8  = v; break;
        }
    }
}

bool DCWorldExt::is_native_daily_visual_commit_pending() const {
    return _native_daily_visual_commit_pending;
}

void DCWorldExt::complete_native_daily_visual_commit() {
    _native_daily_visual_commit_pending = false;
}

void DCWorldExt::complete_native_daily_moisture_commit() {
    complete_native_daily_visual_commit();
}

void DCWorldExt::refresh_slots_from_map_keys(const PackedStringArray &slot_names) {
    SimTraceWriteGuard sim_trace_guard{this, "refresh_slots_from_map_keys"};
    if (!_map_data) return;
    for (int k = 0; k < slot_names.size(); ++k) {
        const StringName requested(slot_names[k]);
        if (_native_daily_visual_commit_pending &&
            requested == StringName("cell_moisture")) {
            continue;
        }
        const int sid = component_id(requested);
        if (sid < 0 || sid >= _slots.size()) continue;
        if (sid < static_cast<int>(_economy_resource_slot_resident.size()) &&
            _economy_resource_slot_resident[static_cast<size_t>(sid)] != 0) {
            continue;
        }
        const int bind_index = _bind_index_for_slot(sid);
        if (bind_index < 0) continue;
        Slot &s = _slots.write[sid];
        Variant v = _map_data->get(StringName(BIND_TABLE[bind_index].property_name));
        switch (s.dtype) {
            case SlotDType::F32: s.arr_f32 = v; break;
            case SlotDType::I32: s.arr_i32 = v; break;
            case SlotDType::U8:  s.arr_u8  = v; break;
        }
    }
}
