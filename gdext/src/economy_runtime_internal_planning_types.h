// Included inside NativeEconomyRuntime; preserve declaration order and access.
private:
    friend class TradeVisualCache;
    friend class EconomyRecordSource;
    // The Country worker gate must not be represented by a bool: callers need
    // to distinguish an operation that is not routed through the worker from
    // one that is pending or has been rejected by the gate.
    enum class CountryWorkerAssetRoute : uint8_t {
        NOT_APPLICABLE = 0,
        ENQUEUED_PENDING = 1,
        TERMINAL_ERROR = 2,
        // Country worker is the unique writer, but this operation is not in
        // the M1 fiscal peer set yet. Callers must soft-skip (no second writer,
        // no economy-wide fatal) until M2–M5 peer journals exist.
        GATE_SOFT_UNAVAILABLE = 3,
    };
    enum StructuralOpcode : int32_t {
        STRUCTURAL_BIRTH = -1,
        STRUCTURAL_REMOVE_EMPTY = 0,
        // BEGIN army personnel lane (contract §1.2). These two records are the
        // only path by which a lane transfer touches the population store, so
        // the cohort side runs on the structural commit stage exactly like a
        // cohort migration (§ military-recruitment-pipeline rule 5).
        //   cell      = cohort cell (source for embark, destination for disembark)
        //   signature = cohort signature
        //   population= heads to move
        //   funds     = army handle (never a slot id)
        //   sequence  = originating command sequence (idempotency)
        STRUCTURAL_ARMY_EMBARK = 1,
        STRUCTURAL_ARMY_DISEMBARK = 2,
        // END army personnel lane
    };
    enum class Stage : int32_t {
        IDLE = 0,
        EPOCH_BEGIN = 1,
        LEDGER_APPLY = 2,
        HOUSEHOLD_MARKET = 3,
        STRUCTURAL_COMMIT = 4,
        WAIT_COMMIT = 5,
        BUILDING_EMPLOYMENT = 6,
        BUILDING_PRODUCTION = 7,
        BUILDING_COMMIT = 8,
        AGGREGATE_PUBLISH = 9,
        FATAL = 10,
        TRADE_SETTLE = 11,
        TRADE_DISPATCH = 12,
        TRADE_PLANNING = 13,
        BUILDING_PLAN = 14,
        GOVERNMENT_RESEARCH_PROCUREMENT = 15,
        FAMILY_COMMIT = 16,
        PERSON_COMMIT = 17,
        FISCAL_SETTLEMENT = 18,
    };

    struct CountryResearchProcurementCandidate {
        int32_t country = -1;
        int32_t market = -1;
        int32_t good = -1;
        int64_t price = 0;
    };

    // Durable-in-epoch continuation for the Country/Economy research
    // procurement outbox.  The phase is intentionally explicit: a call may
    // end after any transition without losing the selected market, merchant
    // allocation or transaction identity.
    struct CountryResearchProcurementContinuation {
        bool active = false;
        // 0=idle, 1=country_prepare, 2=peer_prepared,
        // 3=country_applied, 4=peer_apply, 5=completed,
        // 6=rejected, 7=faulted.
        int32_t phase = 0;
        int32_t candidate_index = -1;
        int32_t country = -1;
        int32_t market = -1;
        int32_t good = -1;
        int64_t quantity = 0;
        int64_t cash = 0;
        int64_t merchant_population = 0;
        int64_t merchant_population_prefix = 0;
        int64_t merchant_distributed = 0;
        uint64_t transaction_id = 0;
        uint64_t session_epoch = 0;
        uint64_t country_generation = 0;
        uint64_t peer_generation = 0;
        // Host wire identity while Country is the unique writer. Reused across
        // prepare/service pulses exactly like fiscal pending_request_id.
        uint64_t pending_request_id = 0;
        // True when Country cash/TP commit travels via Host terminal instead of
        // the sync begin/commit/ack state machine.
        bool host_peer = false;
        size_t merchant_cursor = 0;
        bool market_applied = false;
        std::vector<int32_t> living_merchants;
        // Population of each living merchant when merchant_population was
        // summed. The credit may land on a later pulse; live populations can
        // have moved by then and would no longer add up to cash.
        std::vector<int64_t> merchant_weights;
        std::string last_error;
    };

    // One expedition cargo purchase may cross the Country worker boundary.
    // Keep its wire identity and market application state until the Country
    // terminal is observed; otherwise preparation re-enqueues the same order
    // every day and the expedition cargo never grows.
    struct FamilyExpeditionProcurementContinuation {
        bool active = false;
        int32_t phase = 0; // 1=market purchase, 4=market apply, 5=treasury transfer, 6=peer ack
        int32_t expedition = -1;
        int32_t source_cell = -1;
        int32_t market = -1;
        int32_t good = -1;
        uint8_t cargo_flags = 0;
        int64_t quantity = 0;
        int64_t cash = 0;
        uint64_t transaction_id = 0;
        uint64_t session_epoch = 0;
        uint64_t country_generation = 0;
        uint64_t peer_generation = 0;
        uint64_t pending_request_id = 0;
        bool host_peer = false;
        bool market_applied = false;
        // Set once the treasury cash paid for this cargo is booked as a non-tax
        // fiscal outflow: phase 4 can be retried on country backpressure.
        bool cash_booked = false;
        size_t merchant_cursor = 0;
        int64_t merchant_population = 0;
        int64_t merchant_population_prefix = 0;
        int64_t merchant_distributed = 0;
        int64_t started_day = -1;
        std::vector<int32_t> living_merchants;
        // Frozen at start: the Country terminal arrives days later, after
        // merchant populations may have changed.
        std::vector<int64_t> merchant_weights;
        std::string last_error;
    };

    // Runtime-only diagnostic of the last rejected procurement line per
    // preparing expedition. Not saved or hashed: it only lets the planner skip
    // a line rejected today and lets the UI explain a stalled 0% stockpile.
    struct FamilyExpeditionProcurementRejection {
        uint32_t generation = 0;
        int32_t good = -1;
        uint8_t cargo_flags = 0;
        int64_t day = -1;
        std::string reason;
    };

    // Fiscal settlement is a peer boundary too. Keep the per-country
    // return/collect work outside the stack so a large country set can yield
    // without rebuilding the already aggregated fiscal rows.
    struct FiscalSettlementContinuation {
        bool active = false;
        // 退款终态已确认后，收税续跑不得重新进入退款步骤。
        bool return_completed = false;
        // 0=idle, 1=settling countries, 2=completed, 3=faulted.
        int32_t phase = 0;
        int32_t country_cursor = 0;
        int32_t country_count = 0;
        int64_t day_index = -1;
        int64_t last_unused = 0;
        int64_t last_collected = 0;
        // A host transport retry must reuse one wire identity until the
        // terminal result is observed. This is intentionally separate from
        // the Country transaction id, which is owned by the Host request.
        uint64_t pending_request_id = 0;
        std::vector<int64_t> unused_by_country;
        std::vector<int64_t> collected_by_country;
        std::string last_error;
    };

    // Generalized Country/Economy peer terminal journal (fiscal + M2–M5).
    // Base fields persist under SAVE_SECTION_FISCAL_PEER (schema 52 shape).
    // Extended D7 contract fields persist under SAVE_SECTION_D7_PEER_EXT
    // when SCHEMA_VERSION >= 53 (aligned with ECP2 schema 53 cutover).
    struct FiscalPeerJournalRecord {
        uint64_t request_id = 0;
        uint64_t transaction_id = 0;
        uint64_t session_epoch = 0;
        uint64_t country_handle = 0;
        uint64_t country_generation = 0;
        uint64_t peer_generation = 0;
        uint64_t committed_peer_generation = 0;
        int64_t day = -1;
        int64_t effective_day = -1;
        uint64_t operation_sequence = 0;
        uint64_t sequence = 0;
        uint32_t continuation_index = 0;
        uint32_t source_domain = static_cast<uint32_t>(RuntimeDomainId::COUNTRY);
        uint32_t target_domain = static_cast<uint32_t>(RuntimeDomainId::ECONOMY);
        int32_t country_slot = -1;
        RuntimeEconomyAssetOperation operation = RuntimeEconomyAssetOperation::FISCAL_RESERVE;
        RuntimeEconomyAssetResultCode result_code = RuntimeEconomyAssetResultCode::REJECTED;
        RuntimeEconomyAssetState state = RuntimeEconomyAssetState::REJECTED;
        RuntimeD7ReservationState reservation_state = RuntimeD7ReservationState::REJECTED;
        RuntimeD7TerminalResult terminal_result = RuntimeD7TerminalResult::REJECTED;
        uint8_t accepted = 0;
        int64_t requested_quantity = 0;
        int64_t requested_cash = 0;
        int64_t committed_quantity = 0;
        int64_t committed_cash = 0;
        uint64_t retry_identity = 0;
        uint64_t state_hash_before = 0;
        uint64_t state_hash_after = 0;
        std::array<char, RUNTIME_ECONOMY_ASSET_REASON_CAPACITY> reason{};
        std::array<char, RUNTIME_ECONOMY_ASSET_REASON_CAPACITY> late_ack_rejection_reason{};
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(request_id); visit(transaction_id); visit(session_epoch); visit(country_handle);
            visit(country_generation); visit(peer_generation); visit(committed_peer_generation);
            visit(day); visit(effective_day); visit(operation_sequence); visit(sequence);
            visit(continuation_index); visit(source_domain); visit(target_domain); visit(country_slot);
            visit(static_cast<uint16_t>(operation)); visit(static_cast<uint8_t>(result_code));
            visit(static_cast<uint8_t>(state)); visit(static_cast<uint8_t>(reservation_state));
            visit(static_cast<uint8_t>(terminal_result)); visit(accepted);
            visit(requested_quantity); visit(requested_cash); visit(committed_quantity); visit(committed_cash);
            visit(retry_identity); visit(state_hash_before); visit(state_hash_after);
            visit(reason); visit(late_ack_rejection_reason);
        }
    };
    using AssetPeerJournalRecord = FiscalPeerJournalRecord;
    static uint64_t fiscal_record_digest(const FiscalPeerJournalRecord &record);
    mutable std::map<uint64_t, uint64_t> _fiscal_record_digests;
    mutable std::vector<uint64_t> _fiscal_hash_words;
    mutable RuntimeChunkHash _fiscal_hash_pages;
    mutable bool _fiscal_digest_rebuild = true;
    mutable bool _fiscal_words_dirty = true;
    mutable size_t _fiscal_hash_dirty_from_word = 0;
    struct OwnerOpportunityQuote;
    // FNV-1a over the packed key words. Owner-opportunity keys are small
    // integer vectors; hashing keeps the hot lookup off the tree-compare path
    // while the exact key remains the collision check.
    struct LivingCostVectorKeyHash {
        size_t operator()(const std::vector<int64_t> &key) const noexcept {
            uint64_t hash = 14695981039346656037ull;
            for (const int64_t value : key) {
                hash ^= static_cast<uint64_t>(value);
                hash *= 1099511628211ull;
            }
            return static_cast<size_t>(hash);
        }
    };
    struct LivingCostMemoState {
        const NativeEconomyRuntime *owner = nullptr;
        int32_t depth = 0;
        uint64_t hits = 0, misses = 0;
        std::map<std::array<int32_t, 3>, std::pair<int64_t, int64_t>> values;
        struct PreviewBasis {
            std::vector<int64_t> scores, sums, composites, environment;
            int64_t saturations = 0;
        };
        std::map<std::array<int64_t, 10>, PreviewBasis> previews;
        // 仅覆盖同一冻结 scope；人口资金/岗位变化不影响 plan 自给目标。
        std::map<std::array<int64_t, 4>, std::pair<int64_t, int64_t>> retention_targets;
        bool quote_enabled = false;
        bool frozen_country_preview = false;
        bool frozen_price_overrides = false;
        std::unordered_map<std::vector<int64_t>,
            std::pair<std::shared_ptr<const OwnerOpportunityQuote>, int64_t>,
            LivingCostVectorKeyHash> quotes;
    };
    static LivingCostMemoState &living_cost_memo_state() {
        thread_local LivingCostMemoState state;
        return state;
    }
    struct LivingCostMemoScope {
        NativeEconomyRuntime &runtime;
        bool active = false;
        bool previous_quotes = false;
        bool previous_frozen_country = false;
        bool previous_frozen_prices = false;
        explicit LivingCostMemoScope(NativeEconomyRuntime &owner, bool allow_quotes = false,
                bool frozen_country_preview = false, bool frozen_price_overrides = false) : runtime(owner) {
            auto &state = living_cost_memo_state();
            static const bool memo_disabled = [] {
                const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_DISABLE);
                return value && std::strcmp(value, "1") == 0;
            }();
            if (memo_disabled) return;
            if (frozen_price_overrides) {
                static const bool attribution_disabled = [] {
                    const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_ATTRIBUTION_MEMO_DISABLE);
                    return value && std::strcmp(value, "1") == 0;
                }();
                if (attribution_disabled) return;
            }
            if (state.depth != 0 && state.owner != &owner) return;
            if (state.depth++ == 0) {
                state.owner = &owner;
                state.values.clear();
                state.previews.clear();
                state.retention_targets.clear();
                state.quotes.clear();
                state.hits = state.misses = 0;
            }
            previous_quotes = state.quote_enabled;
            state.quote_enabled = state.quote_enabled || allow_quotes;
            previous_frozen_country = state.frozen_country_preview;
            state.frozen_country_preview = state.frozen_country_preview || frozen_country_preview;
            previous_frozen_prices = state.frozen_price_overrides;
            state.frozen_price_overrides = state.frozen_price_overrides || frozen_price_overrides;
            active = true;
        }
        ~LivingCostMemoScope();
        LivingCostMemoScope(const LivingCostMemoScope &) = delete;
        LivingCostMemoScope &operator=(const LivingCostMemoScope &) = delete;
    };

    // Epoch-open fiscal reservation is a peer transaction boundary as well.
    // Keep the request plan immutable while countries are reserved one at a
    // time so an epoch can yield without recomputing tax lanes or changing
    // the order in which treasury reservations are admitted.
    struct FiscalReservationContinuation {
        bool active = false;
        // 0=idle, 1=reserving countries, 2=completed, 3=faulted.
        int32_t phase = 0;
        int32_t country_cursor = 0;
        int32_t country_count = 0;
        int64_t day_index = -1;
        int64_t last_requested = 0;
        int64_t last_reserved = 0;
        uint64_t pending_request_id = 0;
        std::vector<int64_t> requested_by_country;
        std::string last_error;
    };

    enum class PublishPhase : uint8_t {
        PREPARE = 0,
        AUDIT_POPULATION = 1,
        AUDIT_MARKET = 2,
        AUDIT_TRANSIT = 3,
        AUDIT_ESCROW = 4,
        AUDIT_COUNTRY = 5,
        VERIFY = 6,
        WATERMARK = 7,
        TRADE_FLOW = 8,
        TRADE_DIAGNOSTICS = 9,
        TRADE_INIT = 10,
        COMMIT = 11,
        DONE = 12,
        COUNT = 13,
    };

    static constexpr size_t BUILDING_COMMIT_PHASE_COUNT = 7;

    enum class TradePlanInitPhase : uint8_t {
        IDLE = 0,
        COMPONENT_PREPARE = 1,
        COMPONENT_CLEAR = 2,
        COMPONENT_BUILD = 3,
        PREPARE = 4,
        INFLIGHT_BUILD = 5,
        INFLIGHT_SORT = 6,
        PRUNE = 7,
        INBOUND_BUILD = 8,
        ROTATE = 9,
        WORKSPACE_CLEAR = 10,
        FINALIZE = 11,
        DONE = 12,
    };

#include "economy_runtime_internal_planning_types_buildings.h"
    struct PersonMarketAttribution {
        uint64_t person_handle = 0;
        int64_t consumption_expense = 0;
        int64_t consumption_tax = 0;
        uint16_t satisfaction_q16 = 0;
        uint16_t worst_need_id = std::numeric_limits<uint16_t>::max();
    };

    struct PersonDemographyEvent {
        uint64_t cohort_handle = 0;
        int64_t population_before = 0;
        int64_t deaths = 0;
    };

    // FamilyMembershipEdge / FamilyBuildingOwnership / FamilyTraitRoll: see
    // runtime_economy_family_side_tables.h (aliased above).

    // Compiled family-local behavior factors. This transient CSR is rebuilt
    // only at FAMILY_COMMIT/restore boundaries; consumption, investment and
    // career hot loops never scan the global trait roll table.
    struct FamilyBehaviorFactorRow {
        int32_t cell = -1;
        int32_t score_term = 0;
        int32_t axis = 0;
        int32_t selector_kind = 0;
        int32_t selector_id = 0;
        int32_t factor_q16 = Q16_ONE;
        bool operator==(const FamilyBehaviorFactorRow &other) const {
            return cell == other.cell && score_term == other.score_term &&
                axis == other.axis && selector_kind == other.selector_kind &&
                selector_id == other.selector_id && factor_q16 == other.factor_q16;
        }
    };
    struct FamilyBehaviorSourceRow {
        int32_t family_index = -1;
        FamilyBehaviorFactorRow row;
        bool operator==(const FamilyBehaviorSourceRow &other) const {
            return family_index == other.family_index && row == other.row;
        }
    };

    struct FamilyIndustryStats {
        int32_t family_index = -1;
        int32_t cell = -1;
        uint8_t has_owned_manufacturing = 0;
        int32_t distinct_sector_count = 0;
        int32_t dominant_sector_id = -1;
        int32_t dominant_sector_share_q16 = 0;
        int32_t complete_chain_count = 0;
        int32_t max_local_chain_share_q16 = 0;
        int32_t max_chain_upgrade_family_id = -1;
    };

    struct FamilyOwnedOutputRow {
        int32_t family_index = -1;
        int32_t cell = -1;
        int32_t kind = 0; // 0=all sectors, 1=economic sector, 2=upgrade family.
        int32_t dense_id = 0;
        int32_t factor_q16 = Q16_ONE;
    };

    // FamilyCellInfluenceStore: see runtime_economy_family_side_tables.h
    // (aliased above).

    struct FamilyTraitCommand {
        int32_t operation = 0; // 1=grant, 2=remove, 3=set-strength.
        uint64_t family_handle = 0;
        int32_t trait_id = -1;
        int32_t strength_q16 = Q16_ONE;
        int64_t effective_day = 0;
        int32_t priority = 0;
        int64_t sequence = 0;
        uint64_t submit_order = 0;
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(operation);
            visit(family_handle);
            visit(trait_id);
            visit(strength_q16);
            visit(effective_day);
            visit(priority);
            visit(sequence);
            visit(submit_order);
        }
    };

    static constexpr int32_t FAMILY_FOUNDING_CARD_COUNT = 3;
    static constexpr int32_t FAMILY_FOUNDING_MAX_FAILED_REVIEWS = 6;
    static constexpr uint8_t FAMILY_FOUNDING_OPEN = 1;
    static constexpr uint8_t FAMILY_FOUNDING_SELECTED = 2;

    struct FamilyFoundingCandidate {
        int64_t stable_id = 0;
        int32_t surname_id = -1;
        int32_t culture_group_id = 0;
        uint64_t building_handle = 0;
        int32_t building_type_id = -1;
        int32_t owner_signature_id = -1;
        int64_t founders = 0;
        int32_t effect_id = -1;
        std::vector<int32_t> trait_ids;
        std::vector<int32_t> trait_strength_q16;
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(stable_id);
            visit(surname_id);
            visit(culture_group_id);
            visit(building_handle);
            visit(building_type_id);
            visit(owner_signature_id);
            visit(founders);
            visit(effect_id);
            visit(trait_ids);
            visit(trait_strength_q16);
        }
    };

    struct FamilyFoundingOffer {
        int64_t offer_id = 0;
        uint32_t generation = 1;
        int32_t cell = -1;
        int32_t milestone_index = 0;
        int64_t milestone_population = 0;
        uint8_t status = FAMILY_FOUNDING_OPEN;
        int32_t chosen_index = -1;
        int64_t created_day = 0;
        int32_t failed_reviews = 0;
        uint64_t source_family_handle = 0; // Nonzero: whole local branch split.
        std::vector<FamilyFoundingCandidate> candidates;
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(offer_id);
            visit(generation);
            visit(cell);
            visit(milestone_index);
            visit(milestone_population);
            visit(status);
            visit(chosen_index);
            visit(created_day);
            visit(failed_reviews);
            visit(source_family_handle);
            visit(candidates);
        }
    };

    struct FamilyFoundingChoiceCommand {
        int64_t offer_id = 0;
        uint32_t generation = 0;
        int32_t choice_index = -1;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        uint64_t submit_order = 0;
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(offer_id);
            visit(generation);
            visit(choice_index);
            visit(effective_day);
            visit(sequence);
            visit(submit_order);
        }
    };

    struct FamilyFoundingIdentity {
        int64_t stable_id = 0;
        int32_t surname_id = -1;
        int32_t effect_id = -1;
        const std::vector<int32_t> *trait_ids = nullptr;
        const std::vector<int32_t> *trait_strength_q16 = nullptr;
    };

    struct FamilyModifierBinding {
        uint64_t branch_handle = 0;
        std::string definition_key;
        int32_t magnitude_q16 = 0;
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(branch_handle);
            visit(definition_key);
            visit(magnitude_q16);
        }
    };

    struct FamilyTriggerBinding {
        uint64_t branch_handle = 0;
        std::string definition_key;
        int32_t reward_target = 0;
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(branch_handle);
            visit(definition_key);
            visit(reward_target);
        }
    };

    struct FamilyEffectBinding {
        uint64_t branch_handle = 0;
        std::string definition_key;
        int32_t strength_q16 = 0;
        int64_t instance_id = 0;
        uint32_t generation = 0;
        int32_t target_domain = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        // Which metrics this binding's program reads, copied from
        // FamilyEffectMetadataPod when the binding is created.
        MetricMask metric_mask;
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(branch_handle);
            visit(definition_key);
            visit(strength_q16);
            visit(instance_id);
            visit(generation);
            visit(target_domain);
            visit(target_handle);
            visit(target_generation);
            visit(metric_mask);
        }
    };

    // FamilyExpeditionState / FamilyExpeditionPayload /
    // FamilyExpeditionCargoLine / FamilyExpeditionKitBuilding: see
    // runtime_economy_family_side_tables.h. The enum is a namespace-scope
    // unscoped enum there, so unqualified EXPEDITION_* still resolves here.

    struct ColonizationKitPlan {
        std::vector<FamilyExpeditionKitBuilding> buildings;
        std::vector<FamilyExpeditionCargoLine> cargo;
        std::vector<int32_t> missing_good_ids;
        int64_t supported_population = 0;
        int64_t food_coverage_q16 = 0;
        // Unclamped survival-bridge demand and the part still unfilled after
        // spare source stock and the escrowed reserve. Progress reporting needs
        // the demand before it is clamped to what the market can supply.
        int64_t bridge_required_units = 0;
        int64_t bridge_missing_units = 0;
        // Same reporting contract for the opening build plan: the construction
        // demand of the full intent, and the part of it the source cell still
        // cannot fund. Both are derived per replan and never persisted.
        int64_t material_required_units = 0;
        int64_t material_missing_units = 0;
        // A construction group whose every candidate is unavailable on the
        // source market can never be funded, so preparing would never end.
        uint8_t kit_unbuildable = 0;
        uint8_t kit_partial = 0;
        uint8_t place_buildings = 0;
        uint64_t kit_hash = 0;
        uint64_t dest_identity = 0;
        uint64_t source_stock_identity = 0;
    };

    // Extra stock the kit planner may spend beyond the plain source market:
    // `reserved` is what a preparing party already escrowed (already deducted
    // from the market).
    struct ColonizationReserveContext {
        const std::vector<int64_t> *reserved = nullptr;
        bool prefer_reserved_candidates = false;
        // Read-only demand forecast: retain reachable missing goods in the
        // target bill. Never use this hypothetical cargo for departure.
        bool forecast_missing = false;
    };

    // FamilyExpeditionStore: see runtime_economy_family_side_tables.h
    // (aliased above).

    struct ColonizationQuoteCacheEntry {
        uint64_t token = 0;
        uint64_t country_handle = 0;
        uint64_t family_handle = 0;
        int32_t source_cell = -1;
        int32_t target_cell = -1;
        int64_t maximum_population = 0;
        int32_t route_cost = 0;
        int32_t travel_days = 0;
        uint64_t topology_generation = 0;
        uint64_t country_generation = 0;
        uint64_t vision_hash = 0;
        uint64_t route_hash = 0;
        uint64_t dest_kit_identity = 0;
        uint64_t source_stock_identity = 0;
        uint32_t route_begin = 0;
        uint32_t route_count = 0;
    };

    struct ColonizationReceipt {
        int64_t receipt_id = 0;
        int64_t sequence = 0;
        int64_t effective_day = 0;
        int64_t settled_day = 0;
        uint64_t country_handle = 0;
        uint64_t expedition_handle = 0;
        int32_t target_cell = -1;
        uint8_t kind = 0;
        std::string code;
    };

    struct BuildingRoleSpan {
        int32_t employee_begin = -1;
        int32_t input_begin = -1;
    };

    struct InvestmentExistingType {
        int32_t first_group = -1;
        int32_t last_group = -1;
        int32_t representative_group = -1;
        int64_t installed_count = 0;
        int64_t active_count = 0;
        int64_t suspended_count = 0;
        // Building-equivalent unused capacity in Q16. This is transient review
        // state: offered supply already accounts for the utilized share, so only
        // the unused share is reserved against the remaining demand gap.
        int64_t idle_capacity_q16 = 0;
        int64_t filled_owner = 0;
        int64_t owner_required = 0;
        int64_t last_sold = 0;
        int64_t last_discarded = 0;
        // Revealed active-group settlement totals for incumbent expansion quotes.
        // Review-only; never persisted. last_revenue is already post business tax.
        int64_t sum_last_revenue = 0;
        int64_t sum_last_in_kind_livelihood = 0;
        int64_t sum_last_input_cost = 0;
        int64_t sum_last_base_wages_due = 0;
        int64_t sum_last_maintenance_cost = 0;
        int64_t sum_last_output = 0;
    };

