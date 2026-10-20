#include "metric_mask_tests.h"
#include "metric_mask.h"

namespace pk {
namespace {

bool expect(bool condition, const char *label, std::string &error) {
    if (condition) return true;
    error = label;
    return false;
}

} // namespace

bool MetricMaskTests::run(std::string &error) {
    using Mask = MetricMask;

    // 1. Capacity is the headline number. 64 was the old accidental ceiling;
    //    anything less than 256 would leave L0-1 unfixed.
    if (!expect(Mask::CAPACITY >= 256, "metric_mask_capacity_below_256", error))
        return false;
    if (!expect(Mask::CAPACITY == Mask::WORD_BITS * Mask::WORD_COUNT,
                "metric_mask_capacity_word_math", error)) return false;

    // 2. Ids either side of the old ceiling must be addressable, and the first
    //    id past capacity must not be.
    if (!expect(!Mask::valid(-1), "metric_mask_valid_negative", error)) return false;
    if (!expect(Mask::valid(0), "metric_mask_valid_zero", error)) return false;
    if (!expect(Mask::valid(63), "metric_mask_valid_63", error)) return false;
    if (!expect(Mask::valid(64), "metric_mask_valid_64", error)) return false;
    if (!expect(Mask::valid(Mask::CAPACITY - 1),
                "metric_mask_valid_last", error)) return false;
    if (!expect(!Mask::valid(Mask::CAPACITY),
                "metric_mask_valid_past_capacity", error)) return false;

    // 3. set/test round-trip across every word boundary, plus isolation: setting
    //    one id must not light up its neighbours. Word-boundary off-by-ones are
    //    the realistic bug here, so probe 63/64, 127/128, 191/192.
    for (const int32_t id : {0, 1, 62, 63, 64, 65, 127, 128, 191, 192,
                             Mask::CAPACITY - 1}) {
        Mask mask;
        if (!expect(mask.is_none(), "metric_mask_fresh_is_none", error))
            return false;
        mask.set(id);
        if (!expect(mask.test(id), "metric_mask_set_test_roundtrip", error))
            return false;
        if (!expect(mask.count() == 1, "metric_mask_set_isolated", error))
            return false;
        for (const int32_t other : {id - 1, id + 1}) {
            if (other == id || !Mask::valid(other)) continue;
            if (!expect(!mask.test(other), "metric_mask_set_no_spill", error))
                return false;
        }
        mask.unset(id);
        if (!expect(mask.is_none(), "metric_mask_unset_clears", error))
            return false;
    }

    // 4. Ids outside capacity are ignored rather than corrupting a neighbour.
    {
        Mask mask;
        mask.set(Mask::CAPACITY);
        mask.set(-1);
        mask.set(Mask::CAPACITY + 1000);
        if (!expect(mask.is_none(), "metric_mask_out_of_range_ignored", error))
            return false;
        if (!expect(!mask.test(Mask::CAPACITY), "metric_mask_test_past_end", error))
            return false;
    }

    // 5. The two states that must never collapse into each other.
    {
        Mask empty;
        if (!expect(empty.is_none(), "metric_mask_empty_is_none", error)) return false;
        if (!expect(!empty.is_all(), "metric_mask_empty_not_all", error)) return false;
        Mask all = Mask::all();
        if (!expect(all.is_all(), "metric_mask_all_is_all", error)) return false;
        if (!expect(!all.is_none(), "metric_mask_all_not_none", error)) return false;
        if (!expect(all.count() == Mask::CAPACITY,
                    "metric_mask_all_count", error)) return false;
        for (const int32_t id : {0, 63, 64, 200, Mask::CAPACITY - 1})
            if (!expect(all.test(id), "metric_mask_all_tests_every_id", error))
                return false;
    }

    // 6. all_declared() is "every id the catalogue has", which is what the
    //    samplers mean. Ids at or above the count must stay clear.
    {
        constexpr int32_t kDeclared = 50;
        Mask declared = Mask::all_declared(kDeclared);
        if (!expect(declared.count() == kDeclared,
                    "metric_mask_all_declared_count", error)) return false;
        if (!expect(declared.test(0) && declared.test(kDeclared - 1),
                    "metric_mask_all_declared_bounds", error)) return false;
        if (!expect(!declared.test(kDeclared),
                    "metric_mask_all_declared_excludes_past_end", error))
            return false;
        if (!expect(!declared.is_all(), "metric_mask_all_declared_not_all", error))
            return false;
        // A count past capacity must clamp, not overflow the word array.
        Mask clamped = Mask::all_declared(Mask::CAPACITY + 64);
        if (!expect(clamped.is_all(), "metric_mask_all_declared_clamps", error))
            return false;
    }

    // 7. has_id_at_or_above() is the contract check that keeps a program from
    //    asking for a metric the economy cannot compute.
    {
        Mask mask;
        mask.set(7);
        mask.set(49);
        if (!expect(!mask.has_id_at_or_above(50),
                    "metric_mask_threshold_below_all_clear", error)) return false;
        if (!expect(mask.has_id_at_or_above(50) == false,
                    "metric_mask_threshold_equal_clear", error)) return false;
        if (!expect(mask.has_id_at_or_above(49),
                    "metric_mask_threshold_hit", error)) return false;
        if (!expect(mask.has_id_at_or_above(0),
                    "metric_mask_threshold_zero", error)) return false;
        Mask high;
        high.set(200);
        if (!expect(high.has_id_at_or_above(50),
                    "metric_mask_threshold_high_word", error)) return false;
        if (!expect(!high.has_id_at_or_above(Mask::CAPACITY),
                    "metric_mask_threshold_past_capacity", error)) return false;
        Mask empty;
        if (!expect(!empty.has_id_at_or_above(0),
                    "metric_mask_threshold_empty", error)) return false;
    }

    // 8. Set algebra: the samplers intersect a binding's own mask with the
    //    caller's request, so & and |= have to agree with test().
    {
        Mask left;
        left.set(3);
        left.set(70);
        Mask right;
        right.set(70);
        right.set(150);
        Mask both = left & right;
        if (!expect(both.count() == 1 && both.test(70),
                    "metric_mask_intersect", error)) return false;
        if (!expect(!both.test(3) && !both.test(150),
                    "metric_mask_intersect_excludes", error)) return false;
        Mask unioned = left;
        unioned |= right;
        if (!expect(unioned.count() == 3, "metric_mask_union_count", error))
            return false;
        if (!expect(unioned.test(3) && unioned.test(70) && unioned.test(150),
                    "metric_mask_union_members", error)) return false;
        if (!expect(left == left, "metric_mask_equality_true", error)) return false;
        if (!expect(left != right, "metric_mask_equality_false", error)) return false;
    }

    // 9. count(limit) must never walk past the limit, whatever it is given.
    {
        Mask all = Mask::all();
        if (!expect(all.count(10) == 10, "metric_mask_count_limit", error))
            return false;
        if (!expect(all.count(0) == 0, "metric_mask_count_zero", error)) return false;
        if (!expect(all.count(-5) == 0, "metric_mask_count_negative", error))
            return false;
    }

    return true;
}

} // namespace pk
