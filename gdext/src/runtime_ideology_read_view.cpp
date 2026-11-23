#include "runtime_ideology_read_view.h"

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>

namespace pk {
using namespace godot;

namespace {

template <typename Column>
void gather(const Dictionary &source, Dictionary &out,
            std::initializer_list<const char *> names, const std::vector<int64_t> &indexes) {
    for (const char *name : names) {
        const Column input = source[name];
        Column output;
        output.resize(indexes.size());
        for (size_t i = 0; i < indexes.size(); ++i) output.set(i, input[indexes[i]]);
        out[name] = output;
    }
}

std::vector<int64_t> expand_ranges(const PackedInt32Array &offsets,
        const std::vector<int64_t> &rows, PackedInt32Array &out) {
    out.append(0);
    std::vector<int64_t> indexes;
    for (const auto row : rows) {
        for (int32_t at = offsets[row]; at < offsets[row + 1]; ++at) indexes.push_back(at);
        out.append(static_cast<int32_t>(indexes.size()));
    }
    return indexes;
}

Dictionary unavailable(const char *reason) {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = String(reason);
    return out;
}

} // namespace

Dictionary RuntimeIdeologyReadView::filter_receipts(int64_t after, int32_t limit) const {
    const PackedInt64Array ids = receipts.get("receipt_ids", PackedInt64Array());
    std::vector<int64_t> rows;
    limit = std::clamp(limit, 1, 4096);
    for (int64_t i = 0; i < ids.size() && rows.size() < static_cast<size_t>(limit); ++i)
        if (ids[i] > after) rows.push_back(i);
    Dictionary out;
    gather<PackedInt32Array>(receipts, out,
        {"producer_ids", "statuses", "opcodes", "ideology_ids"}, rows);
    gather<PackedInt64Array>(receipts, out,
        {"receipt_ids", "sequences", "country_handles", "settled_days"}, rows);
    gather<PackedStringArray>(receipts, out, {"reasons"}, rows);
    out["ok"] = true;
    out["count"] = static_cast<int64_t>(rows.size());
    out["latest_receipt_id"] = receipts.get("latest_receipt_id", 0);
    return out;
}

Dictionary RuntimeIdeologyReadView::explain_batch(
        uint64_t handle, const PackedInt32Array &requested) const {
    const auto country = countries.find(handle);
    if (country == countries.end()) return unavailable("ideology_country_unknown");
    const Dictionary &source = country->second.batch;
    if (!static_cast<bool>(source.get("ok", false))) return source.duplicate();
    const PackedInt32Array ids = requested.is_empty()
        ? PackedInt32Array(country->second.state.get("known_ids", PackedInt32Array())) : requested;
    const PackedInt32Array all_ids = source["ideology_ids"];
    std::vector<uint8_t> seen(all_ids.size(), 0);
    PackedInt32Array unique;
    std::vector<int64_t> rows;
    std::vector<int64_t> support_rows;
    for (const int32_t id : ids) {
        if (id < 0 || id >= all_ids.size()) return unavailable("ideology_id_invalid");
        if (seen[id]) continue;
        seen[id] = 1;
        unique.append(id);
        rows.push_back(id);
        for (int32_t direction = 0; direction < 3; ++direction)
            support_rows.push_back(int64_t{id} * 3 + direction);
    }
    Dictionary out;
    gather<PackedInt32Array>(source, out,
        {"support_q16", "support_thresholds_q16", "support_blocking_classes"}, support_rows);
    gather<PackedByteArray>(source, out, {"support_available", "support_allowed"}, support_rows);
    gather<PackedByteArray>(source, out,
        {"equip_allowed", "unequip_allowed", "promote_allowed", "exclusion_allowed"}, rows);
    PackedInt32Array stance_offsets;
    const auto stances = expand_ranges(source["stance_offsets"], rows, stance_offsets);
    gather<PackedInt32Array>(source, out, {"stance_class_indices"}, stances);
    gather<PackedInt64Array>(source, out,
        {"class_influence", "adopt_contributions", "repeal_contributions", "promote_contributions"}, stances);
    PackedInt32Array synergy_offsets;
    const auto synergies = expand_ranges(source["affected_synergy_offsets"], rows, synergy_offsets);
    gather<PackedInt32Array>(source, out, {"affected_synergy_ids"}, synergies);
    gather<PackedByteArray>(source, out, {"current_synergy_active", "equip_synergy_active",
        "unequip_synergy_active", "promote_synergy_active"}, synergies);
    out["ok"] = true;
    out["ideology_ids"] = unique;
    out["stance_offsets"] = stance_offsets;
    out["affected_synergy_offsets"] = synergy_offsets;
    int64_t revision = 0;
    for (const auto index : rows)
        revision = std::max(revision, int64_t(country->second.explanations[index].get("support_revision", 0)));
    out["support_revision"] = revision;
    return out;
}

} // namespace pk
