#pragma once

// Ownership scope for a SOURCE fan-out (plan: 「周围地块」must mean the player's own
// land by default).
//
// WHY THIS IS ITS OWN HEADER
//
// Same reason as `selector_cell_cap.h`: this is pure integer logic with no Godot
// dependency, and it must be unit-testable without linking godot_cpp. Keeping it in
// `effect_runtime.h` made the decode untestable, which is how a wrong default could
// have silently disabled all 71 shipped fan-out cards.
//
// THE BUG THIS ADDRESSES
//
// The fan-out used to be ownership-blind: `collect_effect_target_cells` follows the
// neighbour graph and `accepts()` only checks terrain/resource/predicate
// (`economy_runtime_family_buff.cpp:2646-2664`). A card authored as "周围地块" therefore
// reached FOREIGN cells across a border. Measured: 5x kind 14 + 66x kind 16 = 71
// shipped programs were affected.
//
// STORAGE
//
// Two bits at bit 12 of `target_selector_param[0]`, for EVERY fan-out kind (14/15/16),
// so one decode serves all three. Bits 0..11 are already taken by kind 16's
// cap/radius/source-cap fields, and kinds 14/15 use only 0..4, so 12..13 is the first
// position free in all of them.

#include <cstdint>

namespace pk {

enum OwnershipScope : int32_t {
    // Only cells owned by the card's country. THE DEFAULT: a card that names nothing
    // stays home, which is what "周围地块" reads like to a player.
    OWNERSHIP_OWN = 0,
    // Only cells NOT owned by it. Reserved for the deliberate "hurt the neighbours"
    // design; kept from day one so that intent does not need another schema change.
    OWNERSHIP_FOREIGN = 1,
    // No ownership filter. This is the PRE-CHANGE behaviour, kept nameable so a card
    // that genuinely wants a border-blind sweep can still say so.
    OWNERSHIP_ANY = 2,
};

inline constexpr int32_t OWNERSHIP_SCOPE_SHIFT = 12;
inline constexpr int32_t OWNERSHIP_SCOPE_MASK = 0x3;
// Everything below the scope bits: the fan-out cap for kinds 14/15.
inline constexpr int32_t OWNERSHIP_CAP_MASK =
    (int32_t{1} << OWNERSHIP_SCOPE_SHIFT) - 1;

// Decodes the scope. An unknown value (3) falls back to `ANY`, NOT to `OWN`:
// silently restricting a card whose intent is unclear would make its target set
// vanish with no diagnostic, and an empty target set is indistinguishable from
// "the card matched nothing".
inline constexpr int32_t decode_ownership_scope(int32_t param0) {
    const int32_t raw = (param0 >> OWNERSHIP_SCOPE_SHIFT) & OWNERSHIP_SCOPE_MASK;
    if (raw == OWNERSHIP_OWN || raw == OWNERSHIP_FOREIGN) return raw;
    return OWNERSHIP_ANY;
}

// The cap with the scope bits stripped. A caller that reads `param0` as a cap without
// masking gets the scope bits folded in: `4096 + 32` still clamps to 32, so the bug is
// invisible until a card authors cap 0 (meaning "the kind's default"), where
// `4096 > 0` made the sentinel look authored.
inline constexpr int32_t ownership_stripped_cap(int32_t param0) {
    return param0 & OWNERSHIP_CAP_MASK;
}

// How a target cell relates to the card's country.
//
// THREE cases, not two. The first cut of this header collapsed "another country" and
// "nobody owns it" into a single `is_own == false`, and that made OWNERSHIP_FOREIGN
// include every unowned cell -- neutral land is not "another country". No shipped card
// uses FOREIGN yet, so this was free to fix; leaving it would have shipped a wrong
// semantic into the first card that does.
enum OwnershipRelation : int32_t {
    // Same country as the source.
    OWNERSHIP_RELATION_OWN = 0,
    // A DIFFERENT, real country (slot >= 0 and different).
    OWNERSHIP_RELATION_OTHER_COUNTRY = 1,
    // No country owns it. Unowned cells are represented as NEGATIVE slots
    // (`economy_runtime_family_buff.cpp:953`).
    OWNERSHIP_RELATION_UNOWNED = 2,
};

// `source_slot` and `target_slot` are raw `cell_country_slot()` answers.
inline constexpr OwnershipRelation ownership_relation(int32_t source_slot,
                                                      int32_t target_slot) {
    if (target_slot < 0) return OWNERSHIP_RELATION_UNOWNED;
    if (target_slot == source_slot) return OWNERSHIP_RELATION_OWN;
    return OWNERSHIP_RELATION_OTHER_COUNTRY;
}

// Does a target cell survive the scope?
//
// `FOREIGN` accepts OTHER_COUNTRY only. UNOWNED is accepted by `ANY` alone: neutral
// land belongs to neither side of the own/foreign distinction, and silently folding it
// into either one is how a card ends up affecting terrain its author never considered.
inline constexpr bool ownership_accepts(int32_t scope, OwnershipRelation relation) {
    switch (scope) {
        case OWNERSHIP_OWN:
            return relation == OWNERSHIP_RELATION_OWN;
        case OWNERSHIP_FOREIGN:
            return relation == OWNERSHIP_RELATION_OTHER_COUNTRY;
        default:
            return true;
    }
}

// Convenience for the two-case callers (and for the pure-logic tests): `is_own` true is
// OWN, false is OTHER_COUNTRY. It cannot express UNOWNED on purpose -- a caller that
// cannot tell unowned apart should not be filtering on it.
inline constexpr bool ownership_accepts(int32_t scope, bool is_own) {
    return ownership_accepts(scope, is_own ? OWNERSHIP_RELATION_OWN
                                           : OWNERSHIP_RELATION_OTHER_COUNTRY);
}

inline constexpr const char *ownership_scope_name(int32_t scope) {
    switch (scope) {
        case OWNERSHIP_OWN: return "own";
        case OWNERSHIP_FOREIGN: return "foreign";
        default: return "any";
    }
}

}  // namespace pk
