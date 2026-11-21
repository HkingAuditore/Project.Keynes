#pragma once

#include "runtime_ideology_pod.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <memory>
#include <unordered_map>

namespace pk {

struct DerivedCellFront;

// Latest immutable projections used by the facade and the save providers.
struct RuntimeIdeologyReadView {
    struct CardView {
        godot::Dictionary state;
        godot::Dictionary instances;
        godot::Dictionary targets;
        godot::Dictionary eligibility;
        std::vector<godot::Dictionary> explanations;
        godot::Dictionary batch;
    };

    godot::Dictionary report;
    godot::Dictionary receipts;
    godot::PackedByteArray save;
    std::shared_ptr<const RuntimeIdeologyPodSnapshot> business;
    std::shared_ptr<const DerivedCellFront> derived;
    std::unordered_map<uint64_t, CardView> countries;

    godot::Dictionary filter_receipts(int64_t after, int32_t limit) const;
    godot::Dictionary explain_batch(uint64_t handle, const godot::PackedInt32Array &ids) const;
};

} // namespace pk
