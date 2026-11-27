// Private catalog, country card state, offers, and queued request records.

    struct Level {
        int64_t threshold_q16 = 0;
        int64_t daily_understanding_q16 = 0;
        int32_t persistent_begin = 0;
        int32_t persistent_count = 0;
        int32_t on_enter_begin = 0;
        int32_t on_enter_count = 0;
    };
    struct EffectTemplate {
        int32_t action = 0;
        int32_t domain = -1;
        int32_t opcode = 0;
        int64_t value_q16 = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        std::string command_key;
        std::string definition_key;
        std::array<int64_t, 4> payload{};
    };
    struct Definition {
        std::string stable_id;
        uint8_t acquisition = DISCOVER | DRAW;
        int32_t rarity_weight = 1;
        int32_t ideology_cost = 1;
        int32_t spirit_cost = 1;
        int32_t min_spirit_level = 0;
        int32_t level_begin = 0;
        int32_t level_count = 0;
        int32_t technology_requirement_begin = 0;
        int32_t technology_requirement_count = 0;
        int32_t signal_requirement_begin = 0;
        int32_t signal_requirement_count = 0;
        int32_t gate_requirement_begin = 0;
        int32_t gate_requirement_count = 0;
        int32_t stance_begin = 0;
        int32_t stance_count = 0;
        std::array<int32_t, 3> support_threshold_q16{};
        int32_t exclusion_group_id = -1;
        // Era this idea belongs to. Combined with the country's unlocked era it
        // drives the draw-weight decay curve in the profile.
        int32_t era_index = 0;
        // Primary + up to two secondary build routes (IdeologyCatalog order).
        // Derived catalog metadata; not persisted.
        uint32_t route_mask = 0;
        // X6-c: persistent programs are read from the immediately-left ideology
        // slot. `copyable` is false for Legendary/rule cards, which therefore
        // cannot be copy sources.
        uint8_t copy_left_programs = 0;
        uint8_t copyable = 1;
        int32_t school_index = -1;
    };
    struct ClassStance {
        int32_t class_index = -1;
        std::array<int32_t, 3> stance_q16{};
        std::array<int32_t, 3> critical_min_q16{
            -65537, -65537, -65537};
    };
    struct SynergyRequirement {
        int32_t ideology_id = -1;
        int32_t minimum_level = 0;
        uint8_t location_mask = 0;
    };
    struct Synergy {
        int32_t requirement_begin = 0;
        int32_t requirement_count = 0;
        int32_t effect_begin = 0;
        int32_t effect_count = 0;
        // Active when at least min_count requirement rows hold (school
        // resonances); equals requirement_count for named synergies.
        int32_t min_count = 0;
        // L3-9: rows in `_synergy_override_program_keys/_scales` this synergy
        // applies while active. 0 means "this synergy rewrites nothing", which
        // is every synergy that predates the feature.
        int32_t override_begin = 0;
        int32_t override_count = 0;
    };
    struct SynergyOverride {
        int32_t match_kind = 0;
        int32_t field = 0;
        int32_t value = 0;
        std::string match_value;
        std::string tag_name;
        // 0-based TargetTagTable ids, resolved once when Effect attaches.
        // `match_tag_id` indexes the TAG rows by the selector they match;
        // `tag_id` is the replacement applied by those rows.
        mutable int32_t match_tag_id = -1;
        mutable int32_t tag_id = -1;
        int32_t synergy_id = -1;
    };
    struct CapacityUnlock {
        int32_t technology_id = -1;
        int32_t ideology_delta = 0;
        int32_t spirit_delta = 0;
    };
    struct SupportResult {
        int32_t support_q16 = 0;
        int32_t threshold_q16 = 0;
        int32_t blocking_class = -1;
        uint64_t revision = 0;
        bool available = false;
        bool allowed = false;
    };
    struct IdeaState {
        // One reconciled Effect instance owned by this idea. The list is the
        // previous desired set, so reconciliation can retire exactly the rows
        // that left the set, and a restored save can prove that PKEF still
        // holds every instance this idea claims to own.
        struct EffectInstanceRef {
            uint64_t program_hash = 0;
            uint64_t target_handle = 0;
            uint32_t target_generation = 0;
            int64_t instance_id = 0;
            uint32_t generation = 0;
            // Digest of the metric columns this instance last published. A
            // reconcile that would publish the identical values skips the
            // whole row; without it, every daily reconcile produced one
            // transaction per instance (P1-C). Derived -- `capture()` must not
            // write it, so PKID's layout and hash stay unchanged.
            uint64_t metric_digest = 0;
            // What the last submit told the Effect authority this instance's
            // multiplier is. Compared on the next reconcile so a synergy flip
            // that only changes strength still resubmits -- id and generation
            // alone cannot see it. Derived, never serialised.
            int32_t magnitude_scale_q16 = static_cast<int32_t>(Q16_ONE);
        };
        int32_t ideology_id = -1;
        int64_t understanding_q16 = 0;
        int32_t level = -1;
        uint64_t entered_levels = 0;
        uint32_t generation = 1;
        uint8_t location = INACTIVE;
        // Deterministic order within location; 0 is also the first valid slot.
        // INACTIVE rows retain their last slot so re-equipping after a failed
        // transition has no hidden allocation step.
        uint8_t slot_index = 0;
        int64_t binding_id = 0;
        uint32_t binding_generation = 0;
        uint64_t binding_signature = 0;
        uint64_t binding_program_hash = 0;
        // The displayed state is an intent while an Effect transaction is in
        // flight. The previous state is retained so a rejected transaction can
        // be rolled back without leaking a Modifier or a slot reservation.
        struct Transition {
            uint8_t active = 0;
            int32_t producer_id = 0;
            int64_t command_sequence = 0;
            int32_t command_opcode = 0;
            int32_t previous_level = -1;
            uint64_t previous_entered_levels = 0;
            uint32_t previous_generation = 1;
            uint8_t previous_location = INACTIVE;
            uint8_t previous_slot_index = 0;
            uint64_t entered_on_success = 0;
            std::vector<int64_t> transaction_ids;
            std::vector<int32_t> changed_synergy_ids;
            std::vector<uint8_t> previous_synergy_active;
        } transition;
        std::vector<EffectInstanceRef> effect_instances;
        // P1-A: digest of everything that decides this card's instance set and
        // magnitudes -- identity, level, location, program keys, active
        // synergies, and the economy input revision when the card reads it.
        // Derived: `capture()` must not write it, so PKID stays bit-identical.
        uint64_t activation_signature = 0;
    };
    // A desired instance plus the program key needed to submit it. The key is
    // not persisted (the hash is), so it is rebuilt from the catalog on demand.
    struct EffectActivation {
        IdeaState::EffectInstanceRef ref;
        std::string program;
        // Declared source_kind of the program. submit_instances rejects a
        // managed submission whose source_kind column is absent or mismatched,
        // so every activation has to carry its own.
        int32_t source_kind = 0;
        // Declared target domain (2 = settlement cell, 3 = country, 5 =
        // building/resource inside a cell). Only the cell-targeted domains get
        // metric snapshots published per tick; a COUNTRY program's target handle
        // is a country handle, and sampling it as a cell would read the wrong
        // column entirely.
        int32_t target_domain = 3;
        // The program's declared metric mask, copied out of
        // FamilyEffectMetadataPod. Empty means "this program conditions on
        // nothing", so the publisher does no work for it at all.
        MetricMask metric_mask;
        // Ideology-local scalar inputs use a separate id range in the same
        // Effect metric slab. They are derived from this country's ideology
        // state, never sampled from Economy.
        MetricMask scalar_mask;
        // L3-9: per-instance multiplier derived from the country's ACTIVE
        // synergies, not from the catalog alone -- two countries running the same
        // program can hold different values.
        int32_t magnitude_scale_q16 = static_cast<int32_t>(Q16_ONE);
    };
    // One resolved target cell and its X1-b source-count multiplier. The
    // multiplier composes with the program-level synergy scale before it reaches
    // the Effect instance; Q16_ONE is the identity for every pre-X1-b selector.
    struct EffectTarget {
        uint64_t handle = 0;
        uint32_t generation = 0;
        int32_t magnitude_scale_q16 = static_cast<int32_t>(Q16_ONE);
    };
    struct Offer {
        uint32_t generation = 0;
        // Fixed-capacity, variable-length. `choice_count` is what the draw
        // actually produced and what `choose_offer` validates against; the tail
        // stays -1. A fixed array is kept because the offer crosses the pod /
        // save boundary as plain bytes, and a std::vector there would add an
        // allocation to a struct that is memcpy-friendly today.
        std::array<int32_t, OFFER_CHOICE_CAPACITY> ideology_ids;
        uint8_t choice_count = 0;
        uint8_t active = 0;

        Offer() { ideology_ids.fill(-1); }
        void clear() { ideology_ids.fill(-1); choice_count = 0; active = 0; }
    };
    struct CountryState {
        uint64_t handle = 0;
        int64_t ideology_points_q16 = 0;
        uint64_t rng_state = 0;
        uint64_t draw_sequence = 0;
        // X6-b: OPEN_OFFER consumes one of these before points. Authoritative
        // row state, saved in PKID and mirrored through IDP2.
        uint16_t free_draws = 0;
        // Increment-only point accrual (PKID v4).
        uint64_t points_revision = 0;
        uint8_t baseline_ready = 0;
        uint8_t history_count = 0;
        uint8_t history_head = 0;
        int64_t baseline_population = 0;
        int64_t baseline_buildings = 0;
        int64_t lifetime_points_q16 = 0;
        // Last day this row paid its trade flow. Trade is paid once per day at
        // most, so a second settlement on the same day pays nothing. Without this
        // the total depended on how many times each side settled.
        int64_t trade_paid_day = INT64_MIN;
        RuntimeIdeologyPodPointLedger ledger;
        std::array<int64_t, POINT_HISTORY> history_q16{};
        std::vector<uint64_t> known_bits;
        // Permanently retired cards (封存). Deliberately a second bitmap rather
        // than another meaning for known_bits: un-banning has to stay possible,
        // and "known" drives slot availability, transition ownership and the
        // catalog UI. Folding them together would make a banned card look owned.
        std::vector<uint64_t> banned_bits;
        std::vector<uint64_t> gate_bits;
        std::vector<uint64_t> active_bits;
        std::vector<uint64_t> active_synergy_bits;
        std::vector<IdeaState> ideas;
        std::unordered_map<int32_t, int32_t> idea_indices;
        // IdeaState indices sorted by ideology_id. IdeaState rows are append-only,
        // so these integer indices remain stable across vector reallocations.
        std::vector<int32_t> active_state_indices;
        int32_t ideology_slots_used = 0;
        int32_t spirit_slots_used = 0;
        int32_t pending_transition_count = 0;
        uint64_t opinion_revision = 0;
        std::vector<int64_t> class_influence;
        // Derived, not authoritative: refreshed from the country's completed era
        // milestones at the start of every draw and carried in the save purely so
        // a replay can be diffed. Nothing reads it before refreshing it.
        int32_t unlocked_era = 0;
        Offer offer;
    };
    struct Command {
        int32_t opcode = 0;
        int64_t effective_day = 0;
        int32_t producer_id = 1;
        int32_t source_priority = 0;
        int64_t sequence = 0;
        uint64_t country_handle = 0;
        int32_t ideology_id = -1;
        int64_t value_q16 = 0;
        uint32_t offer_generation = 0;
        int32_t choice_index = -1;
        int32_t gate_id = -1;
        uint64_t submit_order = 0;
    };
    struct Receipt {
        int64_t receipt_id = 0;
        int32_t producer_id = 0;
        int64_t sequence = 0;
        int32_t status = RECEIPT_PENDING;
        int32_t opcode = 0;
        uint64_t country_handle = 0;
        int32_t ideology_id = -1;
        int64_t settled_day = -1;
        std::string reason;
    };
    struct PendingTransitionRef {
        uint64_t country_handle = 0;
        int32_t country_slot = -1;
        int32_t idea_slot = -1;
        uint32_t state_generation = 0;
    };
