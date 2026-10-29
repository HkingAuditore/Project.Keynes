#pragma once

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

    struct BehaviorCommand {
        int32_t action = CUSTOM_DOMAIN_COMMAND;
        int32_t domain = -1;
        int32_t opcode = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int64_t value_q16 = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        // Index into the catalog's behavior_command_keys table. -1 means the
        // behavior uses the domain/opcode default adapter key.
        int32_t command_key_id = -1;
        std::array<int64_t, 4> payload{};
    };
    struct ExternalEffectCommandPod {
        int64_t effect_id = 0;
        int64_t source_id = 0;
        // When true, the Modifier row this command produces is keyed by `source_id`
        // instead of by the per-fire Effect instance id.
        //
        // Synergy rows need this: an activation and its later deactivation are separate
        // fires (different days, and the removal additionally flips bit 63), so an
        // instance-derived identity can never match and the REMOVE silently misses,
        // leaving the row alive forever. A stable `source_id` makes the pair reconcile.
        //
        // Deliberately opt-in. Card tier rows and on-enter one-shots must NOT use it:
        // their identity has to stay per-fire, or a repeated on-enter would be mistaken
        // for "the row already exists" and be swallowed.
        bool stable_source_identity = false;
        std::string program_key;
        uint64_t fire_sequence = 0;
        int32_t action = CUSTOM_DOMAIN_COMMAND;
        int32_t domain = -1;
        int32_t opcode = 0;
        int64_t resolved_value = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        std::string command_key;
        std::string definition_key;
        std::array<int64_t, 4> payload{};
    };
    struct FamilyEffectMetadataPod {
        int32_t source_kind = 0;
        int32_t target_domain = 0;
        int32_t operation = 0;
        int32_t lifecycle = 0;
        int32_t duration_days = -1;
        int32_t stack_policy = 0;
        int32_t max_stacks = 1;
        int32_t priority = 0;
        int32_t target_selector_kind = 0;
        std::string target_selector_id;
        int32_t target_selector_param[2] = {0, 0};
        uint64_t stack_key_hash = 0;
        // Which catalog metrics this program reads. Computed from the program's
        // METRIC_* conditions and READ_METRIC instructions on every request, so
        // it can never go stale against a reloaded catalog. Empty means "this
        // program reads no metrics" and lets the economy skip the cell outright.
        MetricMask metric_mask;
        int32_t magnitude_by_prestige_q16[6] = {
            Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE};
        // Thresholds this program compares metrics against. The economy buckets
        // a metric change by "how many of these did it cross", which is exactly
        // "could a condition have flipped" -- and it needs no per-metric unit
        // knowledge, so it works for population, counts and category ids alike
        // (review §3). Filled on every request like the rest of this struct; it
        // is NOT serialised, so adding it costs no ABI.
        //
        // Overflow past the cap is not an error: that metric simply has an
        // incomplete threshold set, and the digest falls back to exact for it.
        static constexpr int32_t METRIC_THRESHOLD_CAP = 8;
        int32_t metric_threshold_count = 0;
        int32_t metric_threshold_ids[METRIC_THRESHOLD_CAP] = {0};
        // Bucket BOUNDARIES, not raw thresholds: GTE N contributes N, LTE N
        // contributes N+1, EQ N contributes both. Counting "how many boundaries
        // are <= value" then flips exactly where the condition flips, for all
        // three operators. Passing the raw N would leave LTE one boundary late.
        int64_t metric_threshold_values[METRIC_THRESHOLD_CAP] = {0};
        // Metrics that must NOT be bucketed: anything read by READ_METRIC (a Ramp
        // consumes the continuous value, so a bucket would freeze its strength),
        // and anything whose boundaries did not all fit in the cap. Empty
        // threshold set == exact comparison, so marking is all it takes.
        MetricMask exact_metric_mask;
        // Ideology-local scalars live above the Economy range in the same
        // catalog but have no Economy sampler or threshold consumer.
        MetricMask scalar_mask;
    };

    // Durable identity for an external owner (ideology, trigger, etc.).  The
    // transaction row is intentionally reclaimable after ACK; this binding is
    // the compact proof that a peer-owned persistent effect still exists.
    struct ExternalSourceBinding {
        int64_t binding_id = 0;
        uint32_t generation = 1;
        int32_t source_type = 0;
        int64_t source_id = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int32_t level = -1;
        uint8_t location = 0;
        uint8_t active = 0;
        uint64_t template_signature = 0;
        uint64_t program_hash = 0;
    };

    struct BehaviorInput {
        int64_t instance_id = 0;
        uint32_t instance_generation = 0;
        int32_t program_id = -1;
        int32_t level = 0;
        int64_t day = 0;
        uint64_t target_handle = 0;
        uint64_t source_handle = 0;
        const int64_t *metrics = nullptr;
        int32_t metric_count = 0;
    };
    struct BehaviorOutput {
        BehaviorCommand *commands = nullptr;
        int32_t capacity = 0;
        int32_t count = 0;
        bool overflowed = false;

        bool emit(const BehaviorCommand &command) {
            if (commands == nullptr || count < 0 || count >= capacity) {
                overflowed = true;
                return false;
            }
            commands[count++] = command;
            return true;
        }
    };
    using BehaviorFn = bool (*)(const BehaviorInput &, BehaviorOutput &,
                                std::string &error);

    // Compile-time C++ extension point. Registration is cold-path only.
    static bool register_behavior(const std::string &behavior_id,
                                  BehaviorFn fn);
    static bool unregister_behavior(const std::string &behavior_id);
    // F8: POD catalog compile / invoke resolve registered behaviors by id or
    // hash. Missing implementations are hard failures (no silent fallback).
    static BehaviorFn find_behavior(const std::string &behavior_id);
    static BehaviorFn find_behavior_hash(uint64_t behavior_id_hash);
    static bool has_behavior(const std::string &behavior_id);
    static bool invoke_pod_behavior(
        uint64_t behavior_id_hash,
        const struct RuntimeEffectPodBehaviorInput &input,
        struct RuntimeEffectPodBehaviorOutput &output, std::string &error);

    godot::Dictionary configure(const godot::Dictionary &catalog);
    bool pod_snapshot_persistence_self_test(std::string &error) const;
    // M1 acceptance gate: proves the worker POD and this runtime answer every
    // StateId identically. The worker used to carry a second, hand-written
    // state switch that was ordered differently, which made every Q16-authored
    // state threshold permanently false on the worker while it passed here.
    // Runs the full (level, fire_sequence, stack_count, remaining_days) matrix
    // and also pins the POD's capability ceilings to be no narrower than this
    // runtime's, because a narrower ceiling rejects the whole catalog at once.
    bool pod_state_parity_self_test(std::string &error) const;
    // Native domain runtimes use this POD entry point at structural commit
    // boundaries. It avoids constructing Godot Dictionaries in hot loops while
    // keeping EffectRuntime as the sole owner of instance lifecycle.
    bool upsert_instance_pod(int64_t instance_id, const std::string &program_key,
                             uint32_t generation, int32_t source_type,
                             int64_t source_id, uint64_t source_handle,
                             uint64_t target_handle, uint32_t target_generation,
                             int32_t level, int64_t next_due_day, bool active,
                             std::string &error);
    bool has_instance_pod(int64_t instance_id, uint32_t generation) const;
    bool family_effect_metadata_pod(const std::string &program_key,
                                    FamilyEffectMetadataPod &out) const;
    // Catalog-declared cell tags. Empty when the catalog predates the tag
    // tables, which is the normal state for every catalog today. The economy
    // copies this at attach time; nothing here is mutated at runtime.
    const TargetTagTable &target_tags() const { return _target_tags; }
    // Native Modifier adapter of a compiled command definition, indexed the
    // same way the compiled catalog indexes commands. The worker POD must hand
    // the Modifier stage the same adapter the main thread would have used;
    // guessing it from the Modifier domain instead marked ideology cards as
    // TECHNOLOGY and clamped their magnitude to 1.0. Exposed rather than
    // re-derived so the rule has exactly one home (effect_runtime.cpp:1003).
    int32_t native_command_definition_count() const;
    int32_t native_modifier_adapter_for_command(int32_t command_index) const;
    // M2a: the declarative facts EffectRuntime::submit_instances validates with
    // (effect_declarative_validation.h). The worker transport path must reject
    // exactly the rows this returns facts for, so the facts are read here
    // instead of being re-derived from the godot Dictionary columns.
    // Returns false when the program key is unknown or the runtime is
    // unconfigured; `program_id` then stays -1 and callers treat the row as
    // UNKNOWN_PROGRAM.
    bool declarative_facts_for_key(const std::string &key, int32_t &program_id,
                                   int32_t &source_kind,
                                   bool &managed_declared,
                                   int32_t &target_selector_kind,
                                   int32_t *target_selector_param) const;
    // Absolute expiry write. The previous refresh_managed_duration_pod recomputed
    // the day from the definition; callers that already resolved the definition
    // (the family path reads FamilyEffectMetadataPod) pass the absolute day
    // instead, so the main thread and the worker receive the exact same value
    // through EffectInstanceForwarder::InstanceRow::expires_day.
    bool set_instance_expiry_pod(int64_t instance_id, uint32_t generation,
                                 int64_t expires_day);
    bool upsert_external_binding_pod(int64_t binding_id, uint32_t generation,
                                     int32_t source_type, int64_t source_id,
                                     uint64_t target_handle,
                                     uint32_t target_generation, int32_t level,
                                     uint8_t location, uint64_t template_signature,
                                     uint64_t program_hash, std::string &error);
    bool retire_external_binding_pod(int64_t binding_id, uint32_t generation,
                                     std::string &error);
    bool has_external_binding_pod(int64_t binding_id, uint32_t generation,
                                  int32_t source_type, int64_t source_id,
                                  uint64_t target_handle,
                                  uint32_t target_generation, int32_t level,
                                  uint8_t location,
                                  uint64_t template_signature,
                                  uint64_t program_hash) const;
    // Strict restore audit for peer-owned transitions. Every expected
    // transaction must still be pending under the declared external source,
    // and no other pending transaction for the same target may exist.
    bool verify_external_pending_transactions_pod(
        int32_t source_type, uint64_t target_handle, uint64_t source_id_mask,
        const std::vector<int64_t> &expected_transaction_ids,
        const std::vector<uint64_t> &expected_source_ids,
        std::string &error) const;
    bool instance_fire_acked_pod(int64_t instance_id, uint32_t generation) const;
    // Re-queue an existing instance that has not reached a domain ACK, without
    // resetting generation, cadence identity, or fire_sequence.
    bool nudge_unacked_instance_pod(int64_t instance_id, uint32_t generation,
                                    int64_t day_index);
    bool set_metric_pod(int64_t instance_id, int32_t metric_id,
                        int64_t revision, int64_t value_q16,
                        std::string &error);
    // Read back one published metric of one instance.
    //
    // `present` distinguishes "the publisher wrote 0" from "nobody ever wrote".
    // That distinction is the whole point: a METRIC_GTE condition reading a
    // column that was never published is permanently false, and without a
    // presence bit a test cannot tell a correct 0 from a missing pipeline.
    //
    // Returns false when the instance or metric id is unknown. Like
    // instance_fire_acked_pod, this answers from the legacy authority: under
    // EFFECT worker ownership this EffectRuntime is writeback-only and the
    // instance reads as absent, which is why the callers are diagnostics/tests.
    bool instance_metric_pod(int64_t instance_id, int32_t metric_id,
                             int64_t &out_value, bool &out_present) const;
    int32_t metric_count() const noexcept { return _metric_count; }
    int32_t metric_id_for_key(const std::string &key) const;
    // Emits the final native Modifier removal. The instance is reclaimed only
    // after its transaction receives the domain ACK.
    bool retire_instance_pod(int64_t instance_id, uint32_t generation,
                             int64_t effective_day, std::string &error);
    // Converts one already-evaluated Trigger effect into an Effect-owned
    // one-shot transaction. The trigger remains the fact/state owner.
    bool enqueue_trigger_effect_pod(int64_t effect_id, int64_t effective_day,
                                    int32_t trigger_id, uint64_t target_handle,
                                    uint32_t target_generation,
                                    uint64_t fire_sequence, int32_t action,
                                    int32_t domain, int32_t opcode,
                                    int64_t resolved_value, int32_t duration_days,
                                    int32_t stacks, const std::string &command_key,
                                    const std::string &definition_key,
                                    const std::array<int64_t, 4> &payload,
                                    std::string &error);
    // Typed ingress for peer authorities (currently ideology).  The caller
    // supplies a precompiled program and command-template identity; Effect
    // Runtime still owns the transaction, idempotency and domain ACK.
    bool enqueue_external_effect_pod(int64_t effect_id, int64_t effective_day,
                                     int32_t source_type, int64_t source_id,
                                     const std::string &program_key,
                                     uint64_t source_handle, uint64_t target_handle,
                                     uint32_t target_generation,
                                     uint64_t fire_sequence, int32_t action,
                                     int32_t domain, int32_t opcode,
                                     int64_t resolved_value, int32_t duration_days,
                                     int32_t stacks, const std::string &command_key,
                                     const std::string &definition_key,
                                     const std::array<int64_t, 4> &payload,
                                     std::string &error,
                                     int64_t *out_transaction_id = nullptr);
    // Atomically validates and plans one peer-owned transition. Individual
    // command source identities remain on the command rows, while all domains
    // share one transaction reserve, status and aggregate ACK.
    bool enqueue_external_effect_batch_pod(
        int64_t effective_day, int32_t source_type,
        int64_t transition_source_id, uint64_t source_handle,
        uint64_t target_handle, uint32_t target_generation,
        const ExternalEffectCommandPod *commands, size_t command_count,
        std::string &error, int64_t *out_transaction_id = nullptr);
    // Built-in colonization transaction used by the Economy-owned expedition
    // state machine. Unowned targets emit CLAIM then SETTLE and stay unpublished
    // until Country and Economy ACK. Own-country relocation emits SETTLE only.
    bool enqueue_family_colonization_pod(
        int64_t effect_id, int64_t effective_day, int64_t source_id,
        uint64_t country_handle, uint32_t country_generation,
        uint64_t expedition_handle, uint32_t expedition_generation,
        int32_t target_cell, uint64_t fire_sequence, std::string &error,
        int64_t *out_transaction_id = nullptr,
        bool claim_unowned = true,
        int32_t population_reward = 0);
    uint64_t family_colonization_settle_idempotency_key(
        int64_t effect_id, uint32_t expedition_generation,
        uint64_t fire_sequence) const;
    bool family_colonization_includes_claim(int64_t transaction_id) const;
    int32_t family_colonization_population_reward(int64_t transaction_id) const;
    // Built-in geography transaction used by Economy-owned canal projects.
    // The command payload is deliberately only the project handle; the
    // gameplay adapter resolves the bounded route from EconomyRuntime.
    bool enqueue_canal_commit_pod(
        int64_t effect_id, int64_t effective_day, int64_t source_id,
        uint64_t project_handle, uint32_t project_generation,
        uint64_t fire_sequence, std::string &error,
        int64_t *out_transaction_id = nullptr);
    // Peer runtimes retain only transaction IDs. ACKED rows can be compacted,
    // while REJECTED rows remain queryable until their producer observes them.
    int32_t transaction_status_pod(int64_t transaction_id) const;
    bool consume_rejected_transaction_pod(int64_t transaction_id,
                                          int64_t source_id);
    godot::Dictionary submit_instances(const godot::Dictionary &batch);
    godot::Dictionary submit_snapshots(const godot::Dictionary &batch);
    godot::Dictionary run_daily(int64_t day_index);
    // F8 ACTIVE write-back: replace instance/transaction/metric state from the
    // worker-committed POD snapshot. Generation must be monotonic.
    bool apply_pod_snapshot(const struct RuntimeEffectPodSnapshot &snapshot,
                            std::string &error);
    uint64_t pod_snapshot_generation() const { return _pod_snapshot_generation; }
    // Day the committed Effect state belongs to. The split-authority settle uses
    // it as the submission watermark: a worker Modifier snapshot whose
    // `committed_day` is not past it cannot prove anything about rows enqueued
    // today.
    int64_t committed_day() const { return _current_day; }
    // Native production bridge. It submits typed Modifier commands without
    // constructing a Godot Dictionary/Callable per effect transaction.
    godot::Dictionary dispatch_native_modifier(ModifierRuntime *modifier_runtime);
    godot::Dictionary ack_native_modifier(ModifierRuntime *modifier_runtime);
    // ── Split authority: IDEOLOGY on the main thread, EFFECT + MODIFIER on the
    //    worker (mask 0xFEF = 0xFFF with only the ideology bit 0x010 cleared) ──
    //
    // An ideology equip plans its batch HERE, on this main-thread runtime, even
    // when the worker owns EFFECT. Nothing drained it: `run_effect_daily`,
    // `dispatch_effect_native_modifier` and `ack_effect_native_modifier` all
    // report `path=EFFECT_WORKER`, and the POD write-back rebuilt `_transactions`
    // from the worker's table, which by construction never carries a transaction
    // this thread created. The row was therefore erased one day after it was
    // planned: `transaction_status_pod` answered 0 (MISSING) and
    // `poll_pending_transition` reads 0 as failure -> rollback.
    //
    // `apply_pod_snapshot` now PRESERVES these batches and their source
    // instances, and the three calls below finish them. Both sides go through
    // `map_modifier_row`, the single Effect->Modifier mapping
    // `dispatch_native_modifier` also uses, so one row can never be built two
    // different ways.
    static constexpr int32_t IDEOLOGY_SOURCE_TYPE = 0x4944454F; // 'IDEO'
    // One Effect->Modifier row, flattened so it can outlive the transaction
    // arena (no pointer into `_command_definitions`).
    struct ModifierRow {
        int32_t opcode = 0;
        int32_t producer = 0;
        int64_t sequence = 0;
        int64_t effective_day = 0;
        std::string definition_key;
        int32_t domain = 0;
        int32_t scope = 0;
        uint64_t entity_handle = 0;
        uint64_t group_handle = 0;
        uint64_t source_type = 0;
        uint64_t source_id = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        int32_t magnitude_q16 = 65536;
        uint32_t domain_bit = 0;
        // A REMOVE row is confirmed by its ABSENCE from the committed store, an
        // APPLY row by its presence. The distinction is the difference between
        // "the settle worked" and "the settle is waiting".
        bool expect_present = true;
    };
    struct ModifierBinding {
        int64_t transaction_id = 0;
        uint32_t domain_bit = 0;
        int32_t row_begin = 0;
        int32_t row_count = 0;
        int64_t submitted_day = 0;
    };
    // Returns the rows that still need a worker commit, one binding per source
    // transaction. Idempotent: a transaction already bound is not re-collected,
    // which is what keeps a re-entrant settle from stacking the same row twice.
    std::vector<ModifierRow> collect_worker_modifier_rows(int64_t day_index,
                                                          std::vector<ModifierBinding> &out_bindings);
    int32_t worker_modifier_binding_count() const {
        return static_cast<int32_t>(_split_settle_bindings.size());
    }
    const ModifierBinding *worker_modifier_binding(int32_t index) const;
    const ModifierRow *worker_modifier_row(int32_t index) const;
    // Completes each transaction's MODIFIER ack bit. A transaction whose
    // `required_ack_mask` covers more than MODIFIER stays COMMITTED, exactly as
    // the main-thread adapter path leaves it for the other adapters.
    int32_t acknowledge_worker_modifier_rows(const std::vector<int64_t> &transaction_ids);
    // The enqueue failed, so nothing was submitted: forget the binding and put
    // the transaction back to PLANNED so the next settle retries it. Without this
    // a single rejected enqueue would stall the equip forever.
    void discard_worker_modifier_rows(const std::vector<int64_t> &transaction_ids);
    godot::Dictionary dispatch_native_country(NativeCountryRuntime *country_runtime);
    godot::Dictionary ack_native_country(NativeCountryRuntime *country_runtime);
    // Soft-settle leftover PREFLIGHTED Country bindings after a real Host
    // receipt drain under COUNTRY worker authority. Colonization CLAIM/SETTLE
    // still goes through dispatch_native_country + ack_native_country even when
    // EFFECT POD evaluation is worker-owned; do not use this as a substitute
    // for never dispatching those adapters.
    godot::Dictionary settle_orphaned_native_country_acks();
    godot::Dictionary dispatch_native_economy(NativeEconomyRuntime *economy_runtime);
    godot::Dictionary ack_native_economy(NativeEconomyRuntime *economy_runtime);
    godot::Dictionary dispatch_native_gameplay(DCWorldExt *world_ext);
    godot::Dictionary ack_native_gameplay(DCWorldExt *world_ext);
    // Worker-authoritative Effect still needs a main-thread pump for the
    // built-in family colonization transaction.  A freshly created transaction
    // has not reached an adapter binding yet, so expose it to the wake-up
    // predicate instead of reporting the adapters as idle.
    bool has_pending_family_colonization_transactions() const;
    bool should_run(int64_t day_index) const;
    uint64_t catalog_hash() const { return _catalog_hash; }
    // Mutable peer-domain watermark.  This is deliberately distinct from the
    // immutable catalog hash and advances at Effect state commit boundaries.
    uint64_t committed_generation() const { return _committed_generation; }
    godot::Dictionary poll_transactions(int64_t after_transaction_id,
                                         int32_t limit) const;
    godot::Dictionary preflight_transactions(const godot::Dictionary &batch);
    godot::Dictionary commit_transactions(const godot::Dictionary &batch);
    godot::Dictionary ack_transactions(const godot::Dictionary &batch);
    godot::Dictionary explain(int64_t instance_id) const;
    // One authored MODIFIER command of a program, without resolving it.
    // The coefficient plane composes this with ModifierRuntime's
    // definition->(stat, op, value) lookup to learn "which per-cell stat does
    // this card touch, and by how much". Resolving it here would mean Effect
    // knowing about Modifier stat ids, which it deliberately does not.
    struct ProgramModifierCommand {
        std::string definition_key;
        int64_t value_q16 = 0;
        int32_t stacks = 1;
        int32_t duration_days = -1;
        // How `value_q16` is produced. Plan 22 §4.4 condition 4 needs this: a
        // command whose magnitude is `VALUE_CONSTANT` is expressible in the derived
        // layer, while one that reads the stack top (or a metric) is not. Assuming
        // "every city command is stack-top" only holds for today's content, which
        // is why this used to be hard-coded in `cell_program_facts_for`.
        int32_t value_mode = VALUE_STACK_TOP;
    };
    // Evaluates one program against caller-supplied per-cell metric samples.
    // `metric_values` is indexed by metric id. Returns false with `error` when the
    // program is unknown or the stream fails, so the caller can fall back to the
    // instance path rather than silently using 0.
    bool evaluate_program_magnitude_for_metrics(
        const std::string &program_key,
        const int64_t *metric_values, int32_t metric_count,
        int64_t &out_value, std::string &error) const;
    bool program_modifier_commands(const std::string &program_key,
                                   std::vector<ProgramModifierCommand> &out) const;
    godot::Dictionary report() const;
    godot::PackedByteArray capture() const;
    godot::Dictionary restore(const godot::PackedByteArray &bytes);
    godot::Dictionary clear_state();
    void attach_country_runtime(NativeCountryRuntime *runtime) {
        _country_runtime = runtime;
    }
    // Read-only Country state frozen for era-reward planning. Under worker
    // Country authority the attached store is not the committed state, so the
    // caller supplies the committed boundary for the duration of one notify.
    void set_era_reward_country_view(const NativeCountryRuntime *view) {
        _era_reward_country_view = view;
    }
    bool bind_era_reward_player_country_pod(uint64_t country_handle,
                                            std::string &error);
    bool notify_era_reward_technology_activated_pod(
        uint64_t country_handle, int32_t technology_id, int64_t day_index,
        std::string &error);
    godot::Dictionary era_reward_offer_snapshot();
    // host_commit: under worker Effect authority this runtime is a read
    // replica and cannot own transactions. The selection is then recorded
    // without one (transaction_id 0) and the caller commits the selected
    // Modifier commands through the Host, settling via
    // settle_era_reward_selection_pod once they are committed.
    godot::Dictionary choose_era_reward(int64_t offer_generation,
                                        int32_t choice_index,
                                        int64_t effective_day,
                                        bool host_commit = false);
    static constexpr int32_t ERA_REWARD_SOURCE_TYPE = 0x45524152; // ERAR
    struct EraRewardModifierCommand {
        std::string definition_key;
        int32_t domain = 0;
        uint64_t target_handle = 0;
        int32_t magnitude_q16 = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        int64_t source_id = 0;
    };
    bool era_reward_host_selection_pending() const {
        return _era_reward_offer.status == 2 && _era_reward_offer.transaction_id == 0;
    }
    bool era_reward_selected_modifier_commands(
        std::vector<EraRewardModifierCommand> &out, std::string &error) const;
    void settle_era_reward_selection_pod(bool ok, const char *error);

private:
    struct Condition {
        int32_t op = CONDITION_TRUE;
        int32_t arg0 = 0;
        int64_t value = 0;
    };
    struct InstructionRow {
        int32_t op = END;
        int32_t arg0 = 0;
        int32_t arg1 = 0;
        int64_t value = 0;
    };
    enum NativeModifierAdapterKind : int32_t {
        NATIVE_MODIFIER_GENERIC = 0,
        NATIVE_MODIFIER_TECHNOLOGY = 1,
        NATIVE_MODIFIER_FAMILY = 2,
        NATIVE_MODIFIER_PERSON = 3,
        NATIVE_MODIFIER_TRIGGER = 4,
        NATIVE_MODIFIER_FAMILY_EFFECT = 5,
        // Declarative managed programs owned by a domain that is not family
        // (ideology today). Same lifecycle / stack / target semantics, but the
        // modifier producer and source_type stay with the owning domain.
        NATIVE_MODIFIER_IDEOLOGY = 6,
    };
    struct CommandDefinition {
        int32_t action = CUSTOM_DOMAIN_COMMAND;
        int32_t domain = -1;
        int32_t opcode = 0;
        int32_t target_resolver = TARGET_INSTANCE;
        uint64_t static_target = 0;
        int32_t value_mode = VALUE_STACK_TOP;
        int64_t value = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        std::string command_key;
        std::string definition_key;
        int32_t native_modifier_adapter = NATIVE_MODIFIER_GENERIC;
        int32_t owner_program_id = -1;
        std::array<int64_t, 4> payload{};
    };
    struct Definition {
        std::string key;
        int32_t version = 1;
        int32_t cadence_days = 1;
        int32_t max_work = 1024;
        uint8_t enabled = 1;
        int32_t condition_begin = 0;
        int32_t condition_count = 0;
        int32_t instruction_begin = 0;
        int32_t instruction_count = 0;
        int32_t command_begin = 0;
        int32_t command_count = 0;
        std::string behavior_id;
        int32_t source_kind = 0;
        int32_t target_domain = 0;
        int32_t operation = 0;
        int32_t lifecycle = 0;
        int32_t duration_days = -1;
        int32_t stack_policy = 0;
        std::string stack_key;
        int32_t max_stacks = 1;
        int32_t priority = 0;
        int32_t target_selector_kind = 0;
        std::string target_selector_id;
        // [0] = cell cap for the generalised selectors, [1] = terrain id /
        // resource id / predicate id. Both default to 0, which every consumer
        // reads as "unset" rather than "first terrain".
        int32_t target_selector_param[2] = {0, 0};
        // Declared ownership of the managed lifecycle instead of inferring it
        // from a "family.effect." key prefix. Catalog column `managed_flags`
        // wins when present; otherwise the legacy prefix rule applies so every
        // pre-existing catalog and test fixture keeps its behaviour.
        bool managed_declared = false;
        int32_t magnitude_by_prestige_q16[6] = {
            Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE};
    };
    // The stack machine, parameterised on where metric reads come from.
    //
    // Declared AFTER `struct Definition` because it names that type; an earlier
    // placement above the struct failed to compile (C4430/C2143).
    //
    // Extracted from `preview_family_effect_value` so a caller with its own
    // per-cell samples can run the SAME bytecode without an `Instance`. A second
    // evaluator for the derived layer would be one more place to keep in step with
    // the instruction set, and plan §15.5 forbids the simplification that would
    // follow (freezing a Ramp into a threshold bucket).
    bool run_program_machine(
        const Definition &definition,
        const std::function<int64_t(int32_t)> &metric_accessor,
        const std::function<int64_t(int32_t)> &state_accessor,
        int64_t &value, std::string &error) const;
    struct Instance {
        int64_t id = 0;
        uint32_t generation = 1;
        int32_t program_id = -1;
        int32_t source_type = 0;
        int64_t source_id = 0;
        uint64_t source_handle = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int32_t level = 0;
        int64_t next_due_day = 0;
        int64_t input_revision = 0;
        // Highest revision this instance has SEEN, independent of whether that
        // publish changed anything. `input_revision` is the change watermark:
        // it only advances when a metric value actually differs, because
        // downstream work (dirty groups, Modifier remove/re-add, ACK) keys off
        // `input_revision > applied_input_revision`. Splitting the two keeps a
        // genuinely stale snapshot detectable without letting an unchanged
        // publish look like a change. Derived, never serialised.
        int64_t metric_observed_revision = 0;
        // A newer frozen input revision may be evaluated before cadence so an
        // event-driven metric publish is visible in the current simulation day.
        int64_t last_evaluated_input_revision = 0;
        uint64_t fire_sequence = 0;
        uint8_t active = 1;
        // Metrics live in the runtime-wide flat slabs. Keeping only the base
        // row here avoids one heap allocation per instance.
        uint32_t metric_base = 0;
        uint32_t dirty_epoch = 0;
        uint64_t schedule_token = 0;
        int32_t source_kind = 0;
        int32_t target_domain = 0;
        int32_t operation = 0;
        int32_t lifecycle = 0;
        int32_t duration_days = -1;
        int32_t stack_policy = 0;
        int32_t max_stacks = 1;
        // Requested source contribution. Group arbitration derives the
        // applied count without destroying this value, so a capped source can
        // become active when another source leaves the same stack group.
        int32_t stack_count = 1;
        // How many of those stacks the owning domain has actually applied.
        // PKEF carries BOTH this and `effect_applied`, and `restore()` requires them
        // to agree ONLY for a managed definition (`uses_managed_lifecycle`), which is
        // the only place both are advanced together. An unmanaged program's worker
        // write-back legitimately carries `(0, N)`: the POD keeps this count as fire
        // bookkeeping and never sets the latch, because nothing reads the latch for a
        // one-shot program. Reading the two as an unconditional pair is what used to
        // make an EFFECT-worker PKEF unloadable -- see `EffectRuntime::restore`.
        int32_t applied_stack_count = 0;
        int32_t priority = 0;
        // Per-instance magnitude multiplier (L3-9 second slice). The program's
        // compiled `value_q16` is the base; this scales it for THIS instance
        // only, which is the one thing a card can rewrite about another card's
        // program without turning the shared program template into per-instance
        // data. 1.0 means "no override" and is what every pre-existing caller
        // gets, because the batch column is optional.
        int32_t magnitude_scale_q16 = Q16_ONE;
        uint64_t activation_sequence = 0;
        int64_t expires_day = -1;
        uint64_t stack_key_hash = 0;
        // Last evaluation's raw condition result, exposed as STATE_LATCHED.
        // Written wherever a condition is actually evaluated: the day pass on
        // this side, plan_day / set_metric on the worker. The one place that
        // deliberately does NOT write is build_planned_candidate -- it is a dry
        // run whose result may be discarded, so advancing the latch there would
        // let a plan that never executed move the hysteresis band.
        uint8_t latched = 0;
        // Domain-ACKed application state. Managed definitions only emit when
        // this state or the frozen input revision changes.
        uint8_t effect_applied = 0;
        uint8_t retire_requested = 0;
        int64_t applied_input_revision = 0;
        uint64_t last_acked_fire_sequence = 0;
        // Transient arbitration cache. Recomputed once per dirty candidate
        // epoch and intentionally excluded from PKEF.
        uint32_t stack_decision_epoch = 0;
        int32_t desired_stack_count = 0;
    };
    struct Command {
        int32_t action = CUSTOM_DOMAIN_COMMAND;
        int32_t domain = -1;
        int32_t opcode = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int64_t value_q16 = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        // Config commands reference CommandDefinition rows; behavior commands
        // reference the optional behavior_command_keys table.
        int32_t command_key_id = -1;
        int32_t command_definition_id = -1;
        std::array<int64_t, 4> payload{};
        uint64_t idempotency_key = 0;
        int64_t external_effect_id = 0;
        int64_t external_source_id = 0;
        // Mirrors `ExternalEffectCommandPod::stable_source_identity`: when set, the
        // Modifier row this command produces is keyed by `external_source_id` rather than
        // by the per-fire instance id. Only synergy rows opt in (see that field's comment).
        bool external_source_is_stable = false;
    };
    struct Transaction {
        int64_t id = 0;
        int64_t source_instance_id = 0;
        uint32_t source_generation = 0;
        int32_t program_id = -1;
        int64_t effective_day = 0;
        uint64_t plan_hash = 0;
        uint32_t required_ack_mask = 0;
        uint32_t received_ack_mask = 0;
        int32_t status = PLANNED;
        int32_t instance_transition = TRANSITION_NONE;
        int64_t transition_input_revision = 0;
        uint64_t transition_fire_sequence = 0;
        int32_t transition_stack_count = 0;
        uint32_t command_begin = 0;
        uint32_t command_count = 0;
    };
    struct FamilyEffectGroupKey {
        int32_t target_domain = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        uint64_t stack_key_hash = 0;
        bool operator==(const FamilyEffectGroupKey &other) const {
            return target_domain == other.target_domain &&
                target_handle == other.target_handle &&
                target_generation == other.target_generation &&
                stack_key_hash == other.stack_key_hash;
        }
    };
    struct FamilyEffectGroupKeyHash {
        size_t operator()(const FamilyEffectGroupKey &key) const {
            uint64_t value = key.stack_key_hash;
            value ^= key.target_handle + 0x9e3779b97f4a7c15ULL +
                (value << 6U) + (value >> 2U);
            value ^= static_cast<uint64_t>(key.target_generation) << 32U;
            value ^= static_cast<uint32_t>(key.target_domain);
            return static_cast<size_t>(value);
        }
    };
    struct PlannedCandidate {
        int32_t candidate_cursor = -1;
        int32_t instance_index = -1;
        int32_t work = 1;
        uint8_t eligible = 0;
        uint8_t enabled = 0;
        uint8_t passes = 0;
        uint8_t behavior_failure = 0;
        uint8_t overflowed = 0;
        uint64_t planned_fire_sequence = 0;
        uint32_t required_ack_mask = 0;
        std::vector<Command> commands;
        std::string error;
    };
    struct DueNode {
        int64_t day = 0;
        int32_t instance_index = -1;
        uint32_t generation = 0;
        uint64_t schedule_token = 0;
        bool operator>(const DueNode &other) const {
            if (day != other.day) return day > other.day;
            if (instance_index != other.instance_index)
                return instance_index > other.instance_index;
            return schedule_token > other.schedule_token;
        }
    };
    struct NativeAckBinding {
        int64_t transaction_id = 0;
        uint32_t request_begin = 0;
        uint32_t request_count = 0;
        uint32_t domain_bit = 0;
    };
    struct EraRewardRule {
        int32_t code = 0;
        int64_t threshold = 0;
        int32_t multiplier_q16 = Q16_ONE;
        int32_t signal_index = -1;
        int32_t route_technology_begin = 0;
        int32_t route_technology_count = 0;
        std::string reason;
    };
    struct EraRewardOption {
        std::string id;
        std::string title;
        std::string description;
        std::string icon;
        int32_t base_weight = 1;
        uint8_t fallback = 0;
        int32_t eligibility_code = 0;
        int64_t eligibility_threshold = 0;
        int32_t rule_begin = 0;
        int32_t rule_count = 0;
        int32_t program_id = -1;
    };
    struct EraRewardPool {
        std::string id;
        std::string title;
        int32_t trigger_technology = -1;
        uint8_t final_pool = 0;
        int32_t option_begin = 0;
        int32_t option_count = 0;
    };
    struct EraRewardAlternative {
        int32_t option_index = -1;
        int64_t weight = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        std::array<std::string, 2> reasons{};
        int32_t reason_count = 0;
        std::string target_summary;
    };
    struct EraRewardOffer {
        int64_t plan_id = 0;
        int64_t generation = 0;
        int32_t pool_index = -1;
        int32_t milestone_technology = -1;
        uint64_t country_handle = 0;
        uint32_t country_generation = 0;
        int32_t status = 0;
        int32_t selected_choice = -1;
        int64_t transaction_id = 0;
        uint64_t plan_hash = 0;
        std::array<EraRewardAlternative, 3> alternatives{};
        std::string error;
    };

    bool evaluate_condition(const Definition &definition,
                            const Instance &instance) const;
    bool execute_program(const Definition &definition, Instance &instance,
                         int64_t day, Transaction &transaction,
                         std::string &error);
    bool execute_program_plan(const Definition &definition, const Instance &instance,
                              int64_t day, std::vector<Command> &commands,
                              uint32_t &required_ack_mask, std::string &error) const;
    bool build_planned_candidate(int32_t candidate_cursor, int32_t instance_index,
                                 int64_t day, PlannedCandidate &plan) const;
    static void append_planned_command(std::vector<Command> &commands,
                                       uint32_t &required_ack_mask,
                                       const Command &command);
    // The content domain on a Modifier command is a ModifierRuntime subdomain
    // (country/economy/gameplay), not an Effect adapter identity.  ACK state
    // must therefore be keyed by the adapter/action that owns the safe commit
    // boundary, otherwise a Country modifier (domain 1) aliases a Country
    // command (also domain 1) in a mixed transaction.
    static uint32_t adapter_ack_bit_for(const Command &command);
    // THE Effect->Modifier row mapping. `dispatch_native_modifier` and
    // `collect_worker_modifier_rows` both call this: how strong a row is
    // (`magnitude_scale_q16` from the source instance), which source identity it
    // carries (adapter-specific, and the synergy `stable_source_identity` opt-in)
    // and which Modifier scope/handles it targets are all decided HERE, once.
    bool map_modifier_row(const Transaction &transaction,
                          const Instance &source_instance,
                          const Command &command,
                          ModifierRow &out) const;
    int32_t finish_worker_modifier_bindings(
        const std::vector<int64_t> &transaction_ids, bool confirm);
    void append_command(Transaction &transaction, const Command &command);
    void index_transaction_commands(const Transaction &transaction);
    void unindex_transaction_commands(const Transaction &transaction);
    void track_pending_transaction(const Transaction &transaction);
    void untrack_pending_transaction(const Transaction &transaction);
    // Returns true only when this domain ACK completed the transaction's full
    // domain mask. A transaction may otherwise remain COMMITTED while another
    // native domain is still pending at its own safety boundary.
    bool acknowledge_native_domain(Transaction &transaction, uint32_t domain_bit);
    void apply_acked_instance_transition(const Transaction &transaction);
    void apply_rejected_instance_transition(const Transaction &transaction);
    static bool uses_managed_lifecycle(const Definition &definition);
    bool is_family_effect_instance(const Instance &instance) const;
    FamilyEffectGroupKey family_effect_group_key(const Instance &instance) const;
    void add_family_effect_group_member(int32_t instance_index);
    void remove_family_effect_group_member(int32_t instance_index,
                                           const FamilyEffectGroupKey &key);
    void rebuild_family_effect_groups();
    void mark_family_effect_group_dirty(int32_t instance_index);
    bool resolve_family_effect_group(int32_t instance_index, int64_t day,
                                     std::string &error);
    bool preview_family_effect_value(const Definition &definition,
                                     const Instance &instance,
                                     int64_t &value, std::string &error) const;
    void rebuild_command_idempotency_index();
    void compact_terminal_transactions();
    bool create_retirement_transaction(int32_t instance_index,
                                       int64_t effective_day,
                                       std::string &error,
                                       bool retire_instance = true);
    void release_retired_instance_if_terminal(int32_t instance_index);
    const Command *command_at(const Transaction &transaction,
                               uint32_t ordinal) const;
    uint64_t persisted_plan_hash(const Transaction &transaction,
                                const std::vector<Command> &arena) const;
    int32_t transaction_index_for_id(int64_t transaction_id) const;
    int64_t *metric_ptr(Instance &instance, int32_t metric_id);
    const int64_t *metric_ptr(const Instance &instance, int32_t metric_id) const;
    void schedule_instance(int32_t index, int64_t day);
    void compact_due_heap_if_needed();
    void mark_dirty(int32_t index);
    void rebuild_run_candidates(int64_t day_index);
    uint64_t command_idempotency_key(const Instance &instance,
                                     uint32_t command_index) const;
    int32_t definition_id_for_key(const std::string &key) const;
    int32_t instance_index_for_id(int64_t id) const;
    int64_t metric_value(const Instance &instance, int32_t metric_id) const;
    int64_t state_value(const Instance &instance, int32_t state_id) const;
    std::string command_key_for(const Command &command) const;
    std::string command_definition_key_for(const Transaction &transaction,
                                           const Command &command) const;
    void reset_runtime_state();
    void advance_committed_generation();
    bool compile_era_reward_catalog(const godot::Dictionary &catalog,
                                    std::string &error);
    bool plan_era_reward_offer(int32_t pool_index, uint64_t country_handle,
                               int64_t day_index, std::string &error);
    void refresh_era_reward_offer_status();
    bool era_reward_option_eligible(const EraRewardOption &option,
                                    int64_t cash, int32_t territory,
                                    int64_t completed, int64_t signals) const;
    int64_t era_reward_option_weight(const EraRewardOption &option,
                                     int64_t cash, int32_t territory,
                                     int64_t completed, int64_t signals,
                                     const godot::PackedInt32Array &signal_counts,
                                     const godot::PackedInt32Array &technology_states,
                                     std::array<std::string, 2> &reasons,
                                     int32_t &reason_count) const;

    bool _configured = false;
    uint64_t _catalog_hash = 0;
    uint64_t _committed_generation = 1;
    int32_t _metric_count = 0;
    int32_t _max_instances = 4096;
    int32_t _max_transactions = 8192;
    int32_t _max_work_per_slice = 1024;
    int64_t _current_day = -1;
    int64_t _last_completed_day = -1;
    int64_t _run_day = -1;
    int32_t _run_cursor = 0;
    int64_t _next_transaction_id = 1;
    int64_t _acked_transaction_id = 0;
    uint64_t _next_activation_sequence = 1;
    uint64_t _instances_submitted = 0;
    uint64_t _programs_evaluated = 0;
    uint64_t _commands_emitted = 0;
    uint64_t _transactions_acked = 0;
    uint64_t _preflight_rejects = 0;
    uint64_t _behavior_failures = 0;
    uint64_t _overflow_count = 0;
    uint64_t _native_modifier_transactions = 0;
    uint64_t _native_modifier_commands = 0;
    uint64_t _native_modifier_acks = 0;
    uint64_t _native_country_transactions = 0;
    uint64_t _native_country_commands = 0;
    uint64_t _native_country_acks = 0;
    uint64_t _native_economy_transactions = 0;
    uint64_t _native_economy_commands = 0;
    uint64_t _native_economy_acks = 0;
    uint64_t _native_gameplay_transactions = 0;
    uint64_t _native_gameplay_commands = 0;
    uint64_t _native_gameplay_acks = 0;
    double _last_evaluate_ms = 0.0;
    double _last_native_dispatch_ms = 0.0;
    double _last_native_ack_ms = 0.0;
    double _last_parallel_planning_ms = 0.0;
    double _last_parallel_merge_ms = 0.0;
    int32_t _last_parallel_worker_count = 1;
    uint64_t _parallel_dispatches = 0;
    uint64_t _serial_fallback_dispatches = 0;
    std::string _last_parallel_path = "serial";
    std::string _last_parallel_fallback_reason;
    std::string _last_error;
    NativeCountryRuntime *_country_runtime = nullptr;
    const NativeCountryRuntime *_era_reward_country_view = nullptr;

    std::vector<std::string> _metric_keys;
    std::vector<std::string> _behavior_command_keys;
    std::unordered_map<std::string, int32_t> _metric_ids;
    // Optional tag predicate table (see target_tag.h). Owned here because it is
    // catalog data and shares the catalog's lifecycle; consumed by the economy's
    // territory selector, which copies it once instead of reaching through this
    // pointer from a const query path.
    TargetTagTable _target_tags;
    std::vector<Definition> _definitions;
    std::unordered_map<std::string, int32_t> _definition_ids;
    std::vector<Condition> _conditions;
    std::vector<InstructionRow> _instructions;
    std::vector<CommandDefinition> _command_definitions;
    std::vector<BehaviorCommand> _behavior_command_buffer;
    std::vector<Instance> _instances;
    // Retired instances keep their metric slab row and backing slot stable;
    // future upserts reuse these indices without growing instance capacity.
    std::vector<int32_t> _free_instance_indices;
    std::unordered_map<int64_t, int32_t> _instance_ids;
    std::vector<int64_t> _metric_values;
    std::vector<uint8_t> _metric_present;
    std::vector<int32_t> _dirty_queue;
    uint32_t _dirty_epoch_counter = 1;
    uint32_t _stack_decision_epoch = 1;
    std::unordered_map<FamilyEffectGroupKey, std::vector<int32_t>,
                       FamilyEffectGroupKeyHash> _family_effect_groups;
    std::vector<int32_t> _family_effect_candidate_scratch;
    std::priority_queue<DueNode, std::vector<DueNode>, std::greater<DueNode>> _due_heap;
    std::vector<int32_t> _run_candidates;
    int32_t _candidate_cursor = 0;
    uint64_t _schedule_token = 1;
    std::vector<Command> _command_arena;
    std::vector<Transaction> _transactions;
    std::unordered_map<int64_t, int32_t> _transaction_ids;
    std::unordered_map<int64_t, uint32_t> _pending_transactions_by_instance;
    std::unordered_map<uint64_t, uint32_t> _pending_command_idempotency;
    std::vector<ExternalSourceBinding> _external_bindings;
    std::unordered_map<int64_t, int32_t> _external_binding_ids;
    std::vector<int64_t> _native_request_ids;
    std::vector<NativeAckBinding> _native_ack_bindings;
    std::unordered_set<int64_t> _native_bound_transaction_ids;
    std::vector<int64_t> _native_country_request_ids;
    std::vector<NativeAckBinding> _native_country_ack_bindings;
    std::unordered_set<int64_t> _native_country_bound_transaction_ids;
    std::vector<int64_t> _native_economy_request_ids;
    std::vector<NativeAckBinding> _native_economy_ack_bindings;
    std::unordered_set<int64_t> _native_economy_bound_transaction_ids;
    std::vector<int64_t> _native_gameplay_request_ids;
    std::vector<NativeAckBinding> _native_gameplay_ack_bindings;
    std::unordered_set<int64_t> _native_gameplay_bound_transaction_ids;
    // Split-authority settle ledger. Deliberately separate from
    // `_native_*_request_ids`: `apply_pod_snapshot` clears those on every
    // write-back, and losing "already submitted" there would re-enqueue the same
    // row every frame and STACK it (the 1.03 -> 1.0609 defect).
    std::vector<ModifierRow> _split_settle_rows;
    std::vector<ModifierBinding> _split_settle_bindings;
    int32_t _max_native_modifier_commands = 4096;
    std::vector<EraRewardPool> _era_reward_pools;
    std::vector<EraRewardOption> _era_reward_options;
    std::vector<EraRewardRule> _era_reward_rules;
    std::vector<int32_t> _era_reward_route_technology_indices;
    std::unordered_map<int32_t, int32_t> _era_reward_pool_by_technology;
    uint64_t _era_reward_player_country = 0;
    int64_t _era_reward_next_plan_id = 1;
    int64_t _era_reward_next_generation = 1;
    EraRewardOffer _era_reward_offer;
    double _last_era_reward_plan_ms = 0.0;
    uint64_t _era_reward_offers_planned = 0;
    int32_t _last_era_reward_expanded_commands = 0;
    // F8: last applied worker snapshot generation (0 = never applied).
    uint64_t _pod_snapshot_generation = 0;
};

} // namespace pk
