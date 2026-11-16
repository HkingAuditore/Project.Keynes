#pragma once

#include <memory>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace pk {
struct ResourceVisualBuilderState;

// Pure presentation math. One instance belongs to one synchronous build slice;
// its input PackedArrays must not outlive that slice. It never retains a MapData,
// WorldData, Node or callback, and never reads authoritative simulation state.
class NativeResourceVisualBuilder : public godot::RefCounted {
    GDCLASS(NativeResourceVisualBuilder, godot::RefCounted);
public:
    NativeResourceVisualBuilder();
    ~NativeResourceVisualBuilder() override;
    godot::Dictionary configure_slice(const godot::Dictionary &inputs);
    // NIL means an exact tie/non-finite score needs the original script sort.
    // An empty PackedInt32Array is a successful selection with no candidates.
    godot::Variant select_cell(int64_t cell, const godot::PackedByteArray &bands,
            bool source_water) const;
    // Only one selected style is appended. The caller retains rank/occupancy
    // and checks its original deadline between these bounded style steps.
    // False means malformed input; no output was changed, use script semantics.
    bool append_style(int64_t cell, const godot::PackedByteArray &bands,
            int64_t style, int64_t rank, int64_t core, const godot::Vector2 &center,
            bool source_water, const godot::Array &occupied,
            const godot::Array &buffers) const;
protected:
    static void _bind_methods();
private:
    std::unique_ptr<ResourceVisualBuilderState> _state;
};
} // namespace pk
