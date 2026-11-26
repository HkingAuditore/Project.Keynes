#include "economy_runtime.h"
#include "country_api.h"
// Army pay's worker route drives the Country economy-asset peer synchronously
// (prepare -> service -> finish in one epoch), which needs the host's concrete
// type, exactly like economy_runtime.cpp.
#include "economy_host_port.h"

#include <godot_cpp/variant/variant.hpp>
#include <algorithm>
#include <limits>

// Economy side of the army personnel lane.
// Contract: docs/plans/army-personnel-implementation-contract.md §1.
//
// Two rules from docs/cpp-dots-runtime/military-recruitment-pipeline.md decide
// the shape of this file:
//  1. Population is never written directly. A lane transfer only *queues* a
//     structural command; the cohort side of the move happens in
//     commit_structural_army_lane(), i.e. on the ordinary structural path that
//     keeps slot/page bookkeeping and the POD ledger shape valid.
//  2. The same command can reach the switch twice (POD plan plus the epoch
//     drain), so every opcode is deduplicated by `sequence` exactly like the
//     military cohort convert (opcode 24).
