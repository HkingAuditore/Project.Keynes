#pragma once

#include "effect_magnitude.h"
#include "selector_cell_cap.h"
#include "selector_ownership.h"

#include <limits>

#include <algorithm>
#include <array>
#include <cstdint>
#include <functional>
#include <queue>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include "effect_declarative_validation.h"
#include "metric_mask.h"
#include "target_tag.h"

namespace pk {

struct RuntimeEffectReadView {
    godot::Dictionary report;
    godot::Dictionary adapters;
};

class ModifierRuntime;
class NativeCountryRuntime;
class NativeEconomyRuntime;
class DCWorldExt;
struct RuntimeEffectPodBehaviorInput;
struct RuntimeEffectPodBehaviorOutput;
struct RuntimeEffectPodSnapshot;

// Generic effect plan/transaction authority. It evaluates immutable catalog
// programs against submitted POD snapshots and emits typed commands. Domain
// runtimes remain the owners of all authoritative state and acknowledge the
// resulting transactions at their safe commit boundaries.
class EffectRuntime {
public:
    // 材料损益：判断某个 effect 程序的激活条件在当前指标下是否成立。
    // metrics 由调用方按需提供（family / card / incidence 各有自己的指标集）；
    // has_scope_value=false 表示该作用域没有标量（例如全局条件）。
    bool program_conditions_hold(int32_t program_id, const int64_t *metrics,
        int32_t metric_count, int64_t scope_value,
        bool has_scope_value) const;
    bool program_conditions_hold(const std::string &program_key,
        const int64_t *metrics, int32_t metric_count, int64_t scope_value,
        bool has_scope_value) const;

    static constexpr int32_t PROTOCOL_VERSION = 1;
    // 12: Effect instances carry the per-instance magnitude scale (L3-9).
    // 13: the latch is persisted. "One cadence self-heals" was only true while
    //     the only consumer was the daily pass; a save/load straddling a
    //     threshold card lost a whole day of hysteresis, which the replay audit
    //     reads as a divergence rather than a one-off.
    // 14: managed POD instances persist their ACKed lifecycle fields so a
    //     worker/main authority flip cannot replay an APPLY or lose a RETIRE.
    static constexpr int32_t SAVE_SCHEMA_VERSION = 14;
    static constexpr int64_t Q16_ONE = 65536;

    enum Instruction : int32_t {
        CONST = 1,
        READ_METRIC = 2,
        READ_STATE = 3,
        ADD = 4,
        SUB = 5,
        MUL_Q16 = 6,
        DIV_FLOOR = 7,
        MIN = 8,
        MAX = 9,
        CLAMP = 10,
        EMIT_COMMAND = 11,
        END = 12,
    };
    enum ConditionOp : int32_t {
        CONDITION_TRUE = 1,
        METRIC_GTE = 2,
        METRIC_LTE = 3,
        METRIC_EQ = 4,
        STATE_GTE = 5,
        BOOL_AND = 6,
        BOOL_OR = 7,
        BOOL_NOT = 8,
    };
    // Ids accepted as ConditionOp::STATE_GTE's arg0. One source of truth shared
    // by state_value(), the catalog validator and the authored content layer.
    enum StateId : int32_t {
        STATE_LEVEL = 0,
        STATE_FIRE_SEQUENCE = 1,
        STATE_INPUT_REVISION = 2,
        STATE_REMAINING_DAYS = 3,
        // This instance's own stack count. Without it a program cannot express
        // "once this effect has 3 stacks, also do X", which is the backbone of
        // stacking builds.
        STATE_STACK_COUNT = 4,
        // Last evaluation's condition result for THIS instance (0 or Q16_ONE).
        // Exists so a program can express a hysteresis band without a new
        // comparison operator:
        //
        //   OR( AND(STATE_GTE(LATCHED, 1), METRIC_GTE(m, low)),
        //       METRIC_GTE(m, high) )
        //
        // enters at `high` and stays in until `m` falls below `low`. The whole
        // band lives in the authored condition graph; the runtime only supplies
        // the one bit it cannot compute from the present.
        //
        // Persisted since PKEF 13, as part of the instance header. It IS derived
        // state, but "a reset to 0 only means the card must re-cross `high`
        // once" was wrong for the case the band exists for: a save taken inside
        // the band lost a whole day of hysteresis, and a continuous run does
        // not. The one-cadence argument only held while the daily pass was the
        // sole reader.
        STATE_LATCHED = 5,
    };
    // Guardrail for authored max_stacks. state_value() multiplies the stack
    // count by Q16_ONE and downstream terms raise factors to that power, so an
    // unbounded author value overflows int64 instead of failing loudly.
    static constexpr int32_t MAX_AUTHORED_STACKS = 256;
    enum Action : int32_t {
        MODIFIER_COMMAND = 1,
        COUNTRY_COMMAND = 2,
        ECONOMY_COMMAND = 3,
        GAMEPLAY_COMMAND = 4,
        PUBLISH_EVENT = 5,
        CUSTOM_DOMAIN_COMMAND = 6,
    };
    // Native custom-domain adapters. Effect content names these by
    // (action=6, domain=6, opcode); the values are part of PKEF content, not a
    // struct layout, so adding one does not bump the Effect POD ABI.
    static constexpr int32_t CUSTOM_AUDIT_OPCODE = 1;
    static constexpr int32_t CUSTOM_CANAL_COMMIT_OPCODE = 2;
    static constexpr int32_t CUSTOM_IDEOLOGY_FREE_DRAW_OPCODE = 3;
    enum TargetResolver : int32_t {
        TARGET_STATIC = 0,
        TARGET_INSTANCE = 1,
        TARGET_SOURCE = 2,
    };
    enum ValueMode : int32_t {
        VALUE_CONSTANT = 0,
        VALUE_STACK_TOP = 1,
    };
    enum TransactionStatus : int32_t {
        PLANNED = 1,
        PREFLIGHTED = 2,
        COMMITTED = 3,
        ACKED = 4,
        REJECTED = 5,
        RESYNC_REQUIRED = 6,
    };
    enum InstanceTransition : int32_t {
        TRANSITION_NONE = 0,
        TRANSITION_APPLY = 1,
        TRANSITION_UPDATE = 2,
        TRANSITION_DEACTIVATE = 3,
        TRANSITION_RETIRE = 4,
    };

    // Target-selector kinds. Values 6 and 7 predate this enum and are shared
    // with the Economy family-buff path, so the numbering is frozen. 8..11 are
    // generalised selectors that turn "which cells does this effect touch" into
    // a function of world state instead of a fixed handle.
    enum TargetSelectorKind : int32_t {
        SELECTOR_OWNER = 0,
        SELECTOR_SOURCE_CELL = 2,
        SELECTOR_SOURCE_COUNTRY = 3,
        SELECTOR_STATIC_HANDLE = 4,
        SELECTOR_ID = 5,
        SELECTOR_NEIGHBORS_R1 = 6,
        SELECTOR_NEIGHBORS_R2 = 7,
        SELECTOR_SAME_TERRAIN_COMPONENT = 8,
        SELECTOR_SAME_RESOURCE_COMPONENT = 9,
        SELECTOR_PREDICATE_ANY_CELL = 10,
        SELECTOR_DISTANCE_N = 11,
        // 12: the source cell's *owner's* territory, walked through the country
        // territory index instead of the neighbour graph. param1 is a 1-based
        // tag id (0 = every owned cell). See target_tag.h for the tag table.
        //
        // Two things this kind fixes that no existing kind could:
        //   - a hex walk from the anchor can never reach the far side of a
        //     country inside the cell cap, so "which cells does my country
        //     own" was previously unanswerable;
        //   - SELECTOR_PREDICATE_ANY_CELL is grid-wide by definition, so a
        //     country-scoped card using it hit foreign cells. This kind keeps
        //     the grid-wide kind intact (existing content depends on it) and
        //     offers the scoped answer as an explicit opt-in.
        SELECTOR_OWN_TERRITORY = 12,
        // 13: grid-wide cells matching a tag, param1 = 1-based tag id
        // (0 = every cell on the grid).
        //
        // This is the missing quadrant of the 2x2 the two other kinds form on
        // their own. Before it, "every coastal cell anywhere" was not
        // expressible at all: PREDICATE_ANY_CELL only knows river / water /
        // land, and the component kinds follow the anchor's own terrain, so
        // they can never say "cells whose terrain is X" without first being
        // anchored on one. Deliberately a new kind rather than a wider param1
        // on PREDICATE_ANY_CELL: that kind's 1..3 ids are already in shipped
        // content and mean river / water / land, and tag ids start at 1 too,
        // so re-using the slot would silently rewrite existing cards.
        SELECTOR_TAG_ANY_CELL = 13,
        // 14/15: X1 — evaluate the radial selector once per *source* cell.
        //
        // param1 is a 1-based tag id selecting the source cells among the
        // country's own territory; param0 is the total target cap. The engine
        // walks OWN_TERRITORY with that tag, then expands every source cell
        // with the R1 (14) or R2 (15) fan-out, unions the results, sorts and
        // caps. Before this, `resolve_effect_targets` expanded from
        // `country_anchor_cell()` only, so "主产铁矿的地块：周围 1 格工业 +10%"
        // silently applied to the first owned cell's neighbourhood instead of
        // every iron cell's.
        //
        // A new kind rather than a wider param1 on 6/7: param1 there already
        // means "hops" for DISTANCE_N and "predicate id" for PREDICATE_ANY_CELL,
        // and tag ids start at 1 too, so re-using the slot would rewrite
        // existing programs. TAG_ANY_CELL (13) is the grid-wide twin of 14/15
        // and keeps its old meaning.
        SELECTOR_TAG_SOURCE_R1 = 14,
        SELECTOR_TAG_SOURCE_R2 = 15,
        // 16: X1-b per-source COUNT stacking. Same source-tag selection as
        // 14/15, but a target receives one contribution per distinct source
        // within `radius` instead of one unioned contribution.
        //
        // param0 is bit-packed because the POD carries exactly two int slots:
        //   bits 0..4  target cell cap (0 = default 32)
        //   bits 5..7  radius (1..4)
        //   bits 8..11 source-count cap (1..15)
        // param1 remains the 1-based source tag id, like 12..15.
        SELECTOR_TAG_SOURCE_COUNT = 16,
        // 17: X9-b family-owned target. The target domain is 0 (family); the
        // selector resolves stable family handles owned by the country. param0
        // is the family cap and param1 is the minimum active branch count.
        SELECTOR_FAMILY_OWNED = 17,
        SELECTOR_MAX_KIND = SELECTOR_FAMILY_OWNED,
    };
    static constexpr int32_t SOURCE_COUNT_TARGET_CAP_MASK = 0x1F;
    static constexpr int32_t SOURCE_COUNT_RADIUS_SHIFT = 5;
    static constexpr int32_t SOURCE_COUNT_RADIUS_MASK = 0x07;
    static constexpr int32_t SOURCE_COUNT_CAP_SHIFT = 8;
    static constexpr int32_t SOURCE_COUNT_CAP_MASK = 0x0F;
    static constexpr int32_t SOURCE_COUNT_TAG_MASK = 0xFFFF;
    // Ownership scope lives in `selector_ownership.h`: pure integer logic with no
    // Godot dependency, so it can be unit-tested without linking godot_cpp -- the same
    // split `selector_cell_cap.h` made for the cell ceilings.
    using OwnershipScope = pk::OwnershipScope;
    static constexpr int32_t OWNERSHIP_OWN = pk::OWNERSHIP_OWN;
    static constexpr int32_t OWNERSHIP_FOREIGN = pk::OWNERSHIP_FOREIGN;
    static constexpr int32_t OWNERSHIP_ANY = pk::OWNERSHIP_ANY;
    static constexpr int32_t OWNERSHIP_SCOPE_SHIFT = pk::OWNERSHIP_SCOPE_SHIFT;
    static constexpr int32_t OWNERSHIP_SCOPE_MASK = pk::OWNERSHIP_SCOPE_MASK;
    static constexpr int32_t OWNERSHIP_CAP_MASK = pk::OWNERSHIP_CAP_MASK;
    static int32_t decode_ownership_scope(const int32_t *params) {
        if (params == nullptr) return OWNERSHIP_ANY;
        return pk::decode_ownership_scope(params[0]);
    }
    static const char *ownership_scope_name(int32_t scope) {
        return pk::ownership_scope_name(scope);
    }

    struct SourceCountSelector {
        int32_t target_cap = SELECTOR_MAX_CELLS;
        int32_t radius = 0;
        int32_t cap = 0;
        int32_t tag = 0;
        // Decoded from `param[0]` bits 12..13; see `OwnershipScope`.
        int32_t ownership_scope = OWNERSHIP_OWN;
    };
    static SourceCountSelector decode_source_count_selector(
            const int32_t *params) {
        SourceCountSelector out;
        if (params == nullptr) return out;
        const int32_t packed = params[0];
        const int32_t stored_cap = packed & SOURCE_COUNT_TARGET_CAP_MASK;
        // `stored_cap == 0` means the author left the target cap UNSPECIFIED.
        //
        // This used to default to `SELECTOR_MAX_CELLS` (32), which contradicted
        // `selector_cell_ceiling(SELECTOR_TAG_SOURCE_COUNT)` -- that function returns
        // `kSelectorNoCellCap` for this kind, i.e. "not bounded by cell count".
        //
        // The contradiction was not cosmetic: all 66 kind-16 cards author `param0 = 800`,
        // whose low five bits are 0, so every one of them decoded to a 32-cell target cap
        // and `resolve_effect_targets` truncated its target set with
        // `effect_stable_cap(cells, selector.target_cap, ...)`. In a country with more
        // than 32 tagged cells the effect silently stopped applying past the 32nd cell --
        // the same defect that was already fixed for kinds 12, 14 and 15.
        //
        // `effect_stable_cap` treats a negative or oversized cap as "no limit", so the
        // sentinel below removes the truncation without touching that helper.
        out.target_cap = stored_cap == 0 ? kSelectorNoCellCap : stored_cap;
        out.radius = (packed >> SOURCE_COUNT_RADIUS_SHIFT) &
            SOURCE_COUNT_RADIUS_MASK;
        out.cap = (packed >> SOURCE_COUNT_CAP_SHIFT) & SOURCE_COUNT_CAP_MASK;
        out.tag = params[1] & SOURCE_COUNT_TAG_MASK;
        out.ownership_scope = decode_ownership_scope(params);
        return out;
    }
    static bool magnitude_scale_allowed_for_selector(
            int32_t selector_kind, int32_t scale_q16,
            const int32_t *selector_params = nullptr) {
        if (selector_params == nullptr && selector_kind == SELECTOR_TAG_SOURCE_COUNT)
            return false;
        if (scale_q16 < 0 || scale_q16 > 4 * Q16_ONE) return false;
        if (selector_kind != SELECTOR_TAG_SOURCE_COUNT)
            return scale_q16 >= Q16_ONE / 4;
        const SourceCountSelector selector =
            decode_source_count_selector(selector_params);
        const int32_t cap = std::clamp(selector.cap, 1, 15);
        return scale_q16 >= Q16_ONE / cap;
    }
    static int32_t minimum_magnitude_scale_for_selector(
            int32_t selector_kind, const int32_t *selector_params) {
        if (selector_kind != SELECTOR_TAG_SOURCE_COUNT)
            return static_cast<int32_t>(Q16_ONE / 4);
        if (selector_params == nullptr)
            return static_cast<int32_t>(4 * Q16_ONE);
        const SourceCountSelector selector =
            decode_source_count_selector(selector_params);
        return static_cast<int32_t>(
            Q16_ONE / std::clamp(selector.cap, 1, 15));
    }
    // Hard cap on cells a single selector may return. The cap is what keeps
    // "one instance per cell" bounded: 32 cells x a handful of cards stays well
    // inside the instance table, while an uncapped whole-map predicate would not.
    //
    // M2-1: this single constant was being asked to mean two different things,
    // and plan 22 exists because of that confusion:
    //
    //   * a GEOMETRIC bound -- how many cells a radial walk can physically reach.
    //     R1 is the centre plus 6 neighbours (18 with both rings), R2 reaches 37,
    //     radius 3/4 reach 61. Those numbers are properties of the hex geometry.
    //   * a CONTENT POLICY bound -- how many of a country's OWN cells a permanent
    //     card may cover. 32 was never a geometry fact; it was a budget for the
    //     instance table, and it is exactly what plan 22 removes (the derived
    //     backend has no per-cell instance to bound).
    //
    // Keeping one constant for both is why "remove the 32 cap" looked like a
    // one-line change while actually needing three layers changed in order.
    //
    // `SELECTOR_MAX_CELLS` is kept as the geometric ceiling and as the
    // compatibility value for code that has not been split yet. New code should
    // call `selector_cell_ceiling()` with the selector kind.
    // LEGACY INSTANCE PROTECTION (plan 22 §15.7).
    //
    // This bounds how many Effect INSTANCES one card level may create -- nothing else.
    // It is NOT a bound on how many cells a card may reach: the derived path creates no
    // instances and is bounded only by the map size (`selector_cell_cap.h`).
    //
    // The old name `SELECTOR_MAX_CELLS` read like a selector/geometry bound, which is
    // exactly why "remove the 32 cap" looked like a one-line change. Kept because the
    // instance path genuinely still uses it: a wide selector on a card that cannot be
    // derived would otherwise flood the instance table.
    static constexpr int32_t LEGACY_INSTANCE_MAX_CELLS = 32;
    // Deprecated alias. New code must use `LEGACY_INSTANCE_MAX_CELLS` or, for a
    // geometry question, `selector_cell_ceiling(kind)`.
    static constexpr int32_t SELECTOR_MAX_CELLS = LEGACY_INSTANCE_MAX_CELLS;
    static constexpr int32_t SELECTOR_DEFAULT_CELLS = 8;

    // Unbounded sentinel for kinds whose target set is a territory or source
    // query rather than a geometric walk. Callers must still respect the map
    // size; this is "no POLICY cap", not "no limit at all" (§1.1: unbounded is
    // not infinite memory -- the reader side still meters and shards).
    static constexpr int32_t SELECTOR_NO_CELL_CAP = kSelectorNoCellCap;

    // The ceiling for one selector kind lives in `selector_cell_cap.h`, which
    // has no Godot dependency so it can be unit-tested directly (M2-1). It is
    // delegated here so every existing call site keeps working unchanged.
    //
    // Note this is the CEILING; the effective count is still
    // `min(authored_param, ceiling)`, so a card that authors 32 keeps getting 32
    // until its content is updated (M2-1 §3).
    static constexpr int32_t selector_cell_ceiling(int32_t selector_kind) {
        return pk::selector_cell_ceiling(selector_kind);
    }

    static constexpr bool selector_cell_cap_is_unbounded(int32_t selector_kind) {
        return pk::selector_cell_cap_is_unbounded(selector_kind);
    }

    // Guards the duplicated kind ids: a divergence between this header and the
    // pure one fails the build instead of mis-ceiling a kind at runtime.
    static_assert(CAP_SELECTOR_NEIGHBORS_R1 == SELECTOR_NEIGHBORS_R1);
    static_assert(CAP_SELECTOR_NEIGHBORS_R2 == SELECTOR_NEIGHBORS_R2);
    static_assert(CAP_SELECTOR_OWN_TERRITORY == SELECTOR_OWN_TERRITORY);
    static_assert(CAP_SELECTOR_TAG_SOURCE_R1 == SELECTOR_TAG_SOURCE_R1);
    static_assert(CAP_SELECTOR_TAG_SOURCE_R2 == SELECTOR_TAG_SOURCE_R2);
    static_assert(CAP_SELECTOR_TAG_SOURCE_COUNT == SELECTOR_TAG_SOURCE_COUNT);
    static_assert(CAP_SELECTOR_FAMILY_OWNED == SELECTOR_FAMILY_OWNED);

#include "effect_runtime_behavior.h"
#include "effect_runtime_authority_bridge.h"
private:
#include "effect_runtime_state.h"
};

} // namespace pk
