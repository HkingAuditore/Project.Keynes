#pragma once
#include <string>

namespace pk {

// Self check for MetricMask (infra item L0-1). Declared here rather than in
// metric_mask.h so the production header stays free of test surface, and
// defined in metric_mask_tests.cpp, which SConstruct picks up through
// Glob("src/*.cpp").
//
// Why a C++ self check and not a GDScript test: the mask is a pure value type,
// and its capacity is the whole point of L0-1. Proving 256-bit addressing in
// C++ is the only way to assert ids 64..255 today, because the metric *table*
// is still 50 rows -- the catalogue contract rejects a longer `metric_keys`
// until FAMILY_METRIC_COUNT grows with it.
struct MetricMaskTests {
    // Returns true when every mask assertion holds. On failure `error` names
    // the exact assertion that broke.
    static bool run(std::string &error);
};

} // namespace pk
