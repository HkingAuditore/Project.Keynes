#include "economy_runtime.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <limits>
#include <tuple>
#include <utility>
#include <vector>

// Branch demography, the membership claim ledger and the proportional
// membership split. See docs/cpp-dots-runtime/family-demography-ledger-design.md.
