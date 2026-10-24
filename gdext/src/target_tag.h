#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "metric_mask.h"

namespace pk {

// Tag predicates: the vocabulary that lets a card say "every farmland cell I
// own" instead of "the anchor cell, plus whatever the hex walk reaches".
//
// Why a separate table
// --------------------
// `FamilyEffectMetadataPod` carries `target_selector_param[2]`, and the catalog
// ships it as a flat `count * 2` array (`effect_runtime.cpp`). Widening that to
// 4 slots would have to move the generator, the shape check, the configure-time
// comparison and the signature hash together -- a breaking format change for
// every existing catalog. A *parallel, optional* table costs nothing when
// absent: a catalog without `target_tags` simply has no tags and passes
// unchanged, which is also why this landed without a protocol bump.
//
// Why OR-of-clauses(AND-of-rows)
// --------------==-------------
// The design's tag dictionary needs both shapes:
//   * "grain"  = dominant output is wheat OR rice OR corn OR potato OR cereal
//                -> one clause, five rows, but they must be ORed
//   * "rich in iron" = dominant resource is iron AND its stock share >= 50%
//                -> one clause, two rows, ANDed
// A single flat row list cannot express both, so a tag is a list of *clauses*
// (ORed) and each clause is a list of *rows* (ANDed). That is DNF, and it is
// the smallest shape that covers the dictionary without inventing a new opcode
// per tag. Rows inside a tag MUST be authored non-decreasing by clause id, so
// evaluation is one forward pass with no grouping allocation.
//
// Scale
// -----
// Every threshold is Q16, including ids and counts: `economy_runtime.cpp`
// encodes count and id metrics through `count_q16()`, so "landform == plain"
// is `EQ(metric 10, 0)` and "at least 3 sectors" is `GTE(metric 25, 3 << 16)`.
// One scale for all rows means a tag author never has to ask which metric is
// which kind.

enum TargetTagOp : int32_t {
    TARGET_TAG_GTE = 0,
    TARGET_TAG_LTE = 1,
    TARGET_TAG_EQ = 2,
    TARGET_TAG_NEQ = 3,
    TARGET_TAG_BIT_SET = 4,
    TARGET_TAG_OP_COUNT = 5,
};

struct TargetTagRow {
    int32_t metric_id = -1;
    int32_t op = TARGET_TAG_GTE;
    int64_t threshold_q16 = 0;
    // Rows sharing a clause id inside one tag are ANDed; distinct clause ids
    // inside the same tag are ORed. See the header comment.
    int32_t clause = 0;
};

class TargetTagTable {
public:
    // Ceilings are contracts, not estimates: the economy allocates one bitset
    // of `count() * ceil(cells/64)` words, so an unbounded tag count is an
    // unbounded allocation driven by content.
    static constexpr int32_t MAX_TAGS = 512;
    static constexpr int32_t MAX_ROWS = 8192;

    std::vector<std::string> names;
    std::vector<int32_t> offsets; // names.size() + 1
    std::vector<TargetTagRow> rows;

    void clear() {
        names.clear();
        offsets.clear();
        rows.clear();
    }
    bool is_empty() const { return names.empty(); }
    int32_t count() const { return static_cast<int32_t>(names.size()); }
    // First / past-the-end row index of `tag`, or -1 / -1 when out of range.
    int32_t begin(int32_t tag) const {
        if (tag < 0 || tag >= count()) return -1;
        return offsets[static_cast<size_t>(tag)];
    }
    int32_t end(int32_t tag) const {
        if (tag < 0 || tag >= count()) return -1;
        return offsets[static_cast<size_t>(tag) + 1u];
    }

    // Full structural check. `reason` names the first violated invariant so a
    // malformed catalog fails with a usable message instead of an index crash
    // in the sampler.
    bool valid(std::string &reason) const {
        reason.clear();
        const int32_t tags = count();
        if (tags > MAX_TAGS) {
            reason = "target_tag_count_exceeds_limit";
            return false;
        }
        if (rows.size() > static_cast<size_t>(MAX_ROWS)) {
            reason = "target_tag_row_count_exceeds_limit";
            return false;
        }
        if (tags == 0) {
            // An empty table is the pre-tag catalog. Both companion arrays must
            // be empty too, otherwise the catalog is half-written.
            if (!offsets.empty() || !rows.empty()) {
                reason = "target_tag_offsets_without_tags";
                return false;
            }
            return true;
        }
        if (offsets.size() != static_cast<size_t>(tags) + 1u) {
            reason = "target_tag_offsets_shape_invalid";
            return false;
        }
        if (offsets.front() != 0 ||
            offsets.back() != static_cast<int32_t>(rows.size())) {
            reason = "target_tag_offsets_bounds_invalid";
            return false;
        }
        for (int32_t tag = 0; tag < tags; ++tag) {
            if (names[static_cast<size_t>(tag)].empty()) {
                reason = "target_tag_name_empty";
                return false;
            }
            for (int32_t other = tag + 1; other < tags; ++other) {
                if (names[static_cast<size_t>(tag)] ==
                    names[static_cast<size_t>(other)]) {
                    reason = "target_tag_name_duplicate";
                    return false;
                }
            }
            const int32_t first = offsets[static_cast<size_t>(tag)];
            const int32_t last = offsets[static_cast<size_t>(tag) + 1u];
            if (last < first) {
                reason = "target_tag_offsets_not_monotonic";
                return false;
            }
            if (last == first) {
                // A tag with no rows would silently match nothing, which reads
                // to an author as "the card is broken". Reject it instead.
                reason = "target_tag_has_no_rows";
                return false;
            }
            int32_t previous_clause = -1;
            for (int32_t i = first; i < last; ++i) {
                const TargetTagRow &row = rows[static_cast<size_t>(i)];
                if (row.metric_id < 0 ||
                    row.metric_id >= MetricMask::CAPACITY) {
                    reason = "target_tag_metric_id_invalid";
                    return false;
                }
                if (row.op < 0 || row.op >= TARGET_TAG_OP_COUNT) {
                    reason = "target_tag_op_invalid";
                    return false;
                }
                // Non-decreasing clause ids are what make the single forward
                // pass in matches() correct. A later row with a smaller clause
                // id would be read as a new clause and silently OR the AND
                // groups together.
                if (row.clause < previous_clause) {
                    reason = "target_tag_clause_not_sorted";
                    return false;
                }
                previous_clause = row.clause;
            }
        }
        return true;
    }

    // Union of every metric the table reads. Lets the sampler skip everything
    // else, which is the difference between "one column read per cell" and
    // "compute the whole 50-metric row per cell, twice a second".
    void collect_metric_mask(MetricMask &mask) const {
        for (const TargetTagRow &row : rows)
            if (row.metric_id >= 0) mask.set(row.metric_id);
    }

    static bool row_matches(const TargetTagRow &row, int64_t value) {
        switch (row.op) {
            case TARGET_TAG_GTE: return value >= row.threshold_q16;
            case TARGET_TAG_LTE: return value <= row.threshold_q16;
            case TARGET_TAG_EQ: return value == row.threshold_q16;
            case TARGET_TAG_NEQ: return value != row.threshold_q16;
            case TARGET_TAG_BIT_SET:
                return (value & row.threshold_q16) != 0;
            default: return false;
        }
    }

    // `values` is indexed by metric id (the layout sample_effect_metrics()
    // fills). A row whose metric id falls outside `value_count` reads as "not
    // matched", i.e. fail-closed: a truncated table narrows the target set
    // instead of silently widening it to every cell.
    bool matches(int32_t tag, const int64_t *values,
                 int32_t value_count) const {
        if (values == nullptr) return false;
        const int32_t first = begin(tag);
        const int32_t last = end(tag);
        if (first < 0 || last <= first) return false;
        int32_t clause = -1;
        bool clause_ok = false;
        for (int32_t i = first; i < last; ++i) {
            const TargetTagRow &row = rows[static_cast<size_t>(i)];
            const bool row_ok = row.metric_id >= 0 && row.metric_id < value_count
                ? row_matches(row, values[row.metric_id]) : false;
            if (row.clause != clause) {
                if (clause >= 0 && clause_ok) return true;
                clause = row.clause;
                clause_ok = true;
            }
            clause_ok = clause_ok && row_ok;
        }
        return clause >= 0 && clause_ok;
    }
};

} // namespace pk
