// Included inside NativeEconomyRuntime; preserve declaration order and access.
    struct ReadSubscription {
        ReadKey key;
        uint64_t last_access_us = 0;
        bool pending = true;
    };
    std::shared_ptr<const ReadView> _read_view;
    std::shared_ptr<const BuildingVisualView> _building_visual_view;
    mutable std::mutex _read_subscription_mutex;
    std::vector<ReadSubscription> _read_subscriptions;
    std::atomic<uint32_t> _read_subscription_count{0};
    std::mutex _building_visual_outbox_mutex;
    std::vector<int32_t> _building_visual_outbox;
    uint64_t _read_view_serial = 0;
    uint64_t _read_view_last_refresh_us = 0;
    std::atomic<uint64_t> _read_view_serve_count{0};
    std::atomic<uint64_t> _read_view_eval_count{0};
    std::atomic<uint64_t> _read_view_serve_us_total{0};
    std::atomic<uint64_t> _read_view_serve_us_max{0};
    std::atomic<uint64_t> _read_view_evicted_count{0};
#include "economy_runtime_internal_operations_building_and_transport.h"
#include "economy_runtime_internal_operations_commands.h"
    bool adjust_market_stock(int32_t cell, int32_t good_id, int64_t delta,
                             std::string &error);
    bool publish_epoch_slice(int64_t &work_done, std::string &error);
    void reset_publish_state();
    bool compile_building_catalog(const godot::Dictionary &catalog, std::string &error);
    bool compile_carrying_catalog(const godot::Dictionary &catalog, std::string &error);
    void refresh_epoch_carrying_yields();
    int64_t carrying_mix_q16(int64_t value_q16, int32_t elasticity_q16,
                             int64_t &sat) const;
    int64_t carrying_climate_habitability_q16(int32_t cell, int64_t &sat) const;
    int64_t carrying_resource_stock(int32_t resource_id, int32_t cell) const;
    int64_t cell_k_geo_persons(int32_t cell, int64_t &sat) const;
    int64_t cell_family_surplus_q16(int32_t market, int32_t cell, int32_t family,
                                    int64_t food_filled, int64_t food_desired,
                                    const int64_t *good_demand,
                                    const int64_t *good_sales,
                                    int64_t &sat) const;
    void append_carrying_capacity_fields(godot::Dictionary &out,
                                         int32_t cell_idx) const;
    void commit_food_flow_snapshot();
    // Returns the period food-supported population capacity using both net
    // flow and a bounded, reserve-aware local market stock buffer.
    int64_t food_flow_capacity_for_cell(int32_t cell, int64_t &k_geo,
                                        int64_t &sat) const;
    void accumulate_trade_food_flow(int32_t cell, int32_t good,
                                    int64_t import_qty, int64_t export_qty,
                                    int64_t &sat);
    bool evaluate_building_conditions(int32_t type_id, int32_t cell) const;
    bool cell_has_technology(int32_t cell, int32_t technology_id, bool frozen) const;
    bool cell_has_requirements(int32_t cell, int32_t begin, int32_t end,
                               const std::vector<int32_t> &requirements,
                               bool frozen) const;
    bool cell_has_all_requirements(int32_t cell, int32_t begin, int32_t end,
                                   const std::vector<int32_t> &requirements,
                                   bool frozen) const;
    bool good_production_available(int32_t cell, int32_t good_id,
                                   bool frozen = true) const;
    bool good_market_available(int32_t cell, int32_t good_id,
                               bool frozen = true) const;
    // Soft/production input discovery: physical stock is always usable;
    // empty shelves only admit locally producible (tech-unlocked) SKUs or
    // goods with positive offered supply. Trade-enabled-but-locked goods
    // must not absorb category demand via ghost ceiling prices.
    bool good_input_candidate_available(int32_t cell, int32_t good_id,
                                        bool frozen = true) const;
    // Compatibility name for callers that are explicitly asking for the
    // technology gate (UI/building unlock queries).
    bool good_available(int32_t cell, int32_t good_id, bool frozen = true) const;
    bool profession_available(int32_t cell, int32_t profession_id,
                              bool frozen = true) const;
    bool building_available(int32_t cell, int32_t type_id,
                            bool frozen = true) const;
    bool building_dependency_requirements_met(int32_t cell, int32_t type_id,
                                              bool frozen) const;
    bool building_dependency_group_required_for_operation(int32_t group) const;
    bool building_constructible(int32_t cell, int32_t type_id,
                                bool frozen = true) const;
    int64_t allocated_output_operating_cost(
        const BuildingType &type, int32_t output_index,
        int64_t operating_cost, int64_t &sat) const;
    // O(1) signature lookup helpers backed by _signature_by_profession_ethnicity.
    // Return -1 when no such signature exists (e.g. unemployed profession absent).
    inline int32_t signature_for_profession_ethnicity(int32_t profession_id,
                                                       int32_t ethnicity_id) const {
        if (profession_id < 0 || ethnicity_id < 0) return -1;
        const int32_t n_eth = static_cast<int32_t>(_ethnicity_ids.size());
        if (ethnicity_id >= n_eth) return -1;
        const size_t idx = static_cast<size_t>(profession_id) * static_cast<size_t>(n_eth) +
                           static_cast<size_t>(ethnicity_id);
        if (idx >= _signature_by_profession_ethnicity.size()) return -1;
        return _signature_by_profession_ethnicity[idx];
    }
    inline int32_t unemployed_signature_for_ethnicity(int32_t ethnicity_id) const {
        return signature_for_profession_ethnicity(_unemployed_profession_id, ethnicity_id);
    }
    // Military v1: a state-service (soldier) signature is locked to its own
    // profession. Every outward transfer lane (employee<->employee, owner moves,
    // unemployed reflux, family colonization draw, migration) asks this first.
    inline bool signature_is_state_service_only(int32_t signature_id) const {
        return signature_id >= 0 &&
            static_cast<size_t>(signature_id) < _signatures.size() &&
            profession_is_state_service_only(
                _signatures[static_cast<size_t>(signature_id)].profession_id);
    }
    // Allocation-free per-cell scan used by the outward-transfer guard: true when
    // `cell` still holds at least `people` members of any state-service cohort.
    bool cell_has_state_service_population(int32_t cell) const;
    void configure_satisfaction_profile(const godot::Dictionary &profile);
    bool satisfaction_need_available(const Need &need, int32_t cell) const;
    uint8_t satisfaction_applicable_mask(int32_t slot) const;
    std::array<int64_t, SAT_DIM_COUNT> satisfaction_effective_weights(
        const Signature &signature, uint8_t applicable_mask) const;
    int64_t satisfaction_bias_q16(int32_t cell, const Signature &signature) const;
    int64_t satisfaction_ceiling(const int64_t *dims, uint8_t applicable_mask,
                                const Signature &signature, int32_t &binding_dimension,
                                int64_t &sat) const;
    int32_t consumption_living_standard_level(int32_t slot) const;
    // `out_pending_city_factors` (optional) is set when the city-factor shard
    // yielded and needs another call. It is NOT an error: `start_epoch` must
    // park and resume rather than fail, because failing would abort the day.
    bool capture_country_epoch(std::string &error,
                               bool *out_pending_city_factors = nullptr);
    // Catalog inputs are immutable between configure/reset calls. Compare the
    // actual frozen columns exactly; broad Country generations include cash.
    void refresh_country_availability_cache();
    void refresh_country_territory_cache();
    void rebuild_building_upgrade_requirements();
    void append_epoch_input_report(godot::Dictionary &out) const;
    // Rebuilds _epoch_country_cell_offsets / _epoch_country_cells from
    // _epoch_cell_country. Counting sort in three linear passes, called when
    // captured ownership changes rather than per selector query. Clears both columns when the
    // ownership column is absent or no country count is known, which is what
    // makes the consumers' linear-scan fallback kick in.
    void rebuild_country_territory_index();
    // Rebuilds X12's derived geography columns only when territory or canal
    // topology changed. `geo_flags_rebuilds` is the idle no-op evidence.
    void rebuild_epoch_geo_columns();
    // Rebuilds X9-a's per-cell family aggregates only when a tracked branch
    // column changes. Returns true when the cache was rebuilt.
    bool rebuild_epoch_family_cell_metrics();
    bool rebuild_epoch_family_country_metrics();
    // X13a persistent counters advance once per daily epoch, before the tag
    // snapshot is rebuilt. capture_environment only derives today's hazard.
    bool advance_climate_day_columns(std::string &error);
    // Refreshes X14's country scalars from the last committed class-opinion
    // snapshot at the start of the country epoch capture, reusing the previous
    // rows when the snapshot revision has not advanced.
    void refresh_class_opinion_metrics();
    // Rebuilds X10's per-country technology counts only when the frozen
    // technology bitset content changes. The four domain masks were compiled
    // once at configure.
    void refresh_technology_metrics();
    // R-3: builds BOTH per-epoch tag tables into a NEW immutable `TagSnapshot` and
    // publishes it with a single atomic store. The only writer.
    //
    // Callers must hold the economy input capture lock (`try_lock_economy_input_capture`)
    // or be the thread that owns the epoch columns: the snapshot is built from
    // `_target_tags`, `_cell_count` and `_epoch_cell_country`, so building it while
    // those move would publish a torn answer.
    //
    // R-3b: reentrancy is COUNTED and refused, not compiled away. `_tag_snapshot_building`
    // is the "only one thread may be in here" assertion: two concurrent builds would
    // race on `_published_tag_snapshot_generation` and could publish two snapshots
    // carrying the same generation, which a reader would then read as "unchanged".
    // The loser returns immediately and keeps the previously published snapshot --
    // stale at worst, never torn.
    void rebuild_epoch_tag_snapshot();
    // R-3b: does ANYTHING read the tag bits or metric 67 this epoch?
    //
    // The tables cost a full per-cell metric sample plus a per-country sweep. When
    // the catalog declares neither (an all-national-Modifier catalog, which is 55 of
    // the shipped 85 cards), paying it every epoch is pure waste -- and the caller
    // cannot tell, because the answer is invisible unless someone asks.
    //
    // Conservative on purpose: before any consumer set is published the answer is
    // YES, so a world that never configures ideology, and the selector fixtures that
    // drive `set_target_tags()` directly, keep working with no extra wiring. The
    // skip therefore applies only where something has explicitly declared a consumer
    // set and that set asked for neither.
    bool tag_snapshot_needed() const {
        const std::shared_ptr<const EffectInputConsumers> consumers =
            std::atomic_load_explicit(&_effect_input_consumers,
                std::memory_order_acquire);
        if (consumers == nullptr) return true;
        return consumers->tags_needed || consumers->metric_mask.test(
            FAMILY_METRIC_COUNTRY_DISTINCT_SPECIALIZED_GOOD_COUNT);
    }
    // Whether the TAG BITS half is wanted (vs metric 67, which owns its own pass).
    bool tag_bits_needed() const {
        const std::shared_ptr<const EffectInputConsumers> consumers =
            std::atomic_load_explicit(&_effect_input_consumers,
                std::memory_order_acquire);
        if (consumers == nullptr) return true;
        return consumers->tags_needed;
    }
    bool specialized_good_count_needed() const {
        const std::shared_ptr<const EffectInputConsumers> consumers =
            std::atomic_load_explicit(&_effect_input_consumers,
                std::memory_order_acquire);
        if (consumers == nullptr) return true;
        return consumers->metric_mask.test(
            FAMILY_METRIC_COUNTRY_DISTINCT_SPECIALIZED_GOOD_COUNT);
    }
    // Counters behind the lazy decision. `tag_snapshot_builds` is the evidence that
    // the skip works: an idle epoch whose catalog uses no tags must not increment it.
    uint64_t tag_snapshot_builds() const {
        return _tag_snapshot_builds.load(std::memory_order_relaxed);
    }
    uint64_t tag_snapshot_skips() const {
        return _tag_snapshot_skips.load(std::memory_order_relaxed);
    }
    uint64_t tag_snapshot_concurrent_writes() const {
        return _tag_snapshot_concurrent_writes.load(std::memory_order_relaxed);
    }
    // The published tables, or null before the first commit. ONE atomic load: the
    // returned pointer keeps the storage alive for the whole read even if a later
    // epoch swaps in a replacement, which is what makes readers safe without a lock.
    std::shared_ptr<const TagSnapshot> tag_snapshot() const {
        // R-3b: counts every load, so a per-cell loop that took the lock once per cell
        // is visible as a number instead of as a mysterious latency.
        _tag_snapshot_loads.fetch_add(1, std::memory_order_relaxed);
        auto snapshot = std::atomic_load_explicit(&_tag_snapshot,
                                                  std::memory_order_acquire);
        if (snapshot == nullptr)
            _last_tag_snapshot_miss_count.fetch_add(1, std::memory_order_relaxed);
        return snapshot;
    }
    // Total `tag_snapshot()` calls. Exported so the "load once outside the loop" rule
    // is checkable: a selector that scans N cells must cost O(1) loads, not O(N).
    int64_t tag_snapshot_loads() const {
        return _tag_snapshot_loads.load(std::memory_order_relaxed);
    }
    // R-3b: the per-CELL half of `cell_has_target_tag`, split out so a loop can do
    // the `atomic_load` ONCE and still ask per cell.
    //
    // `atomic_load(shared_ptr)` on MSVC takes a process-wide spin lock (the refcount
    // bump is not lock-free), so the old shape -- one load per cell, inside a
    // per-cell loop -- serialized every thread in the process against every tag scan.
    // Callers with a loop must load once and pass the snapshot in.
    static bool snapshot_has_tag(const TagSnapshot *snapshot, int32_t cell,
                                 int32_t tag) {
        if (snapshot == nullptr || tag < 0 || cell < 0) return false;
        if (snapshot->tag_words <= 0) return false;
        const size_t index = static_cast<size_t>(tag) *
            static_cast<size_t>(snapshot->tag_words) + static_cast<size_t>(cell / 64);
        if (index >= snapshot->tag_bits.size()) return false;
        return (snapshot->tag_bits[index] & (uint64_t{1} << (cell % 64))) != 0;
    }
    // Number of readers that found the tag snapshot unbuilt. Must be 0 on any world
    // that has completed one commit, so a caller that starts reading before commit
    // is visible instead of silently getting empty bits.
    // M4 observability: how long a tag-snapshot rebuild costs, and how many of
    // them happened. The M4 task list asks for "stamp / touched scratch, per-tag
    // changed words" -- a per-change incremental update -- and that is only worth
    // building if a FULL rebuild is actually expensive. These two numbers are what
    // decides it; without them the optimisation would be speculation.
    double last_tag_snapshot_build_ms() const {
        return _last_tag_snapshot_build_ms.load(std::memory_order_relaxed);
    }
    int64_t tag_snapshot_build_count() const {
        return _tag_snapshot_build_count.load(std::memory_order_relaxed);
    }
    int64_t last_tag_snapshot_miss_count() const {
        return _last_tag_snapshot_miss_count.load(std::memory_order_relaxed);
    }
    // X7: per-country counts live inside the same `TagSnapshot` (see
    // `tag_snapshot()`), because they are derived from the same tag bits and must
    // never be read from a different epoch than the bits they describe.
    // Counts, per country, how many distinct goods have at least one specialized
    // cell. Built into the epoch `TagSnapshot`; there is no lazy path any more.
    // True when the CSR is self-consistent with _epoch_country_count, i.e. its
    // slice table covers every slot and its last offset equals the cell list
    // length. Consumers use this to decide between O(1) index reads and the
    // linear-scan fallback, so a half-built index can never be read.
    bool country_territory_index_ready() const;
    void refresh_epoch_development();
    // Writes the authoritative composite/dimension columns for one cohort and
    // returns the composite. `tier_*_q16` point at the SAT_TIER_COUNT-wide slice
    // the household need reduction just produced for this cohort.
    int64_t update_cohort_satisfaction(int32_t slot, int32_t cell,
                                       int64_t subsistence_q16,
                                       const Signature &signature,
                                       const int64_t *tier_weighted_q16,
                                       const int64_t *tier_weight_q16,
                                       int64_t basic_min_fill_q16,
                                       int64_t &sat);
    int64_t normalize_band_q16(int64_t value, int64_t floor, int64_t ceiling,
                               int64_t &sat) const;
    int32_t living_standard_level_for(int64_t composite_q16) const;
    // Social-pressure level 0..4, ascending with satisfaction: 0 is the most
    // distressed band and 4 is contentment.
    int32_t social_pressure_level_for(int64_t composite_q16) const;
    void publish_social_pressure_facts();
    // Sparse stratum-mobilization (organization) state. Compiled profession
    // floors/weights are initialized lazily from the profession stable ids.
    void ensure_mobilization_profession_config();
    void advance_cell_mobilization(
        int32_t cell, int32_t country, int64_t cell_population,
        int64_t cell_satisfaction, const std::vector<int32_t> &touched,
        const std::vector<int64_t> &profession_population,
        const std::vector<int64_t> &profession_satisfaction);
    // Military-owned per-cell garrison input for suppression odds. Public in
    // economy_runtime.h because Military pushes it through economy_api.
    void reset_stratum_mobilization();
    // Family-domain helper: prestige-weighted support proxy for a cell, in
    // [-Q16, Q16]. Lives in a lineage_* translation unit so the mobilization
    // file does not name a family type across the domain boundary.
    int32_t mobilization_family_backing_q16(int32_t cell) const;
    void rebuild_building_visual_social();
    // Returns true when a presentation band of `cell` changed.
    bool update_building_visual_social(int32_t cell, int64_t population,
                                       int64_t composite_q16, int64_t rich,
                                       int64_t poor);
    void mark_building_visual_cell(int32_t cell);
    void append_building_visual_social_rows(
        const std::vector<int32_t> &cells, godot::Dictionary &out) const;
    void publish_technology_practice_facts();
    void publish_country_development_facts();
    bool prepare_fiscal_budgets(int64_t day_index, std::string &error);
    int64_t prospective_business_subsidy_request(int32_t cell, int32_t country);
#include "economy_runtime_internal_operations_transactions.h"
#include "economy_runtime_internal_operations_stages.h"
public:
    bool track_b_aggregate_hash_reuse(int64_t day, uint64_t &cached_hash);
    void track_b_aggregate_hash_store(int64_t day, uint64_t hash);
private:
    void rebuild_family_policy_scalars();
    void grant_random_pool_family_effect(int32_t family_index,
                                         bool submit_changes);
    void grant_family_effect_to_branches(int32_t family_index,
                                         int32_t effect_id);
    void grant_ancestral_precept_for_country(uint64_t country_handle);
    int32_t family_effect_id_for_key(const std::string &program_key) const;
    int32_t family_effect_prestige_magnitude_q16(int32_t effect_id,
                                                 int32_t prestige_level) const;
    int32_t family_owned_output_factor_q16(int32_t family_index, int32_t cell,
                                           int32_t sector,
                                           int32_t upgrade_family) const;
    int32_t family_scoped_output_factor_q16(uint64_t family_handle) const;
    int32_t family_group_owned_output_factor_q16(int32_t group_index) const;
    const FamilyIndustryStats *family_industry_stats_for(
        int32_t family_index, int32_t cell) const;
    void apply_family_split_policy_flags(int32_t family_index, uint16_t policy,
                                         uint8_t weight_q8);
    void split_family_branches();
    bool build_family_split_offer(int32_t parent, int32_t cell,
                                  FamilyFoundingOffer &offer) const;
    bool resolve_family_split_offer(const FamilyFoundingOffer &offer,
                                    int32_t choice_index);
    void transfer_family_branch(int32_t parent, int32_t child, int32_t cell);
    // commit_ledger is set only at FAMILY_COMMIT: it settles the claim ledger
    // against each cohort's opening basis. Mid-epoch callers only enforce
    // the subset caps.
    void normalize_family_memberships(bool rebuild_derived = true,
                                      bool commit_ledger = false);
    void collect_family_edges_for_cohort(int32_t slot,
                                         std::vector<int32_t> &out) const;
    // Give the investment preview only the data needed to copy its opening claims.
    template <typename Visitor>
    void for_each_cohort_cash_claim(int32_t slot, std::vector<int32_t> &scratch,
                                   Visitor visit) const {
        if (family_memberships().empty()) return;
        collect_family_edges_for_cohort(slot, scratch);
        for (int32_t edge : scratch) {
            const auto &row = family_memberships()[edge];
            visit(row.family_handle, row.people, row.cash_claim);
        }
    }
    int64_t family_ledger_basis_for_slot(int32_t slot) const;
    // Structural funds moves (migration, colonization, capital transfers)
    // shift the cohort's ledger opening so they are not read as flows.
    void shift_family_ledger_basis(int32_t slot, int64_t delta);
    // A funds change in `slot` that belongs to one family (0 = anonymous):
    // the claim moves with it and the basis shifts so it is not re-split.
    void attribute_family_funds_delta(int32_t slot, uint64_t family_handle,
                                      int64_t delta);
    void rebuild_family_demography_weights();
    const FamilyDemographyRow *family_demography_row(uint64_t family_handle,
                                                     int32_t cell) const;
    void apply_family_death_attribution(int32_t slot, int64_t population_before,
                                        int64_t deaths);
    void apply_family_birth_attribution(int32_t slot, int64_t births);
    void settle_family_claim_ledger();
    void recruit_family_dependents();
    void rebuild_family_owner_seats();
    int64_t family_owner_seats(uint64_t cohort_handle, uint64_t family_handle) const;
    // Owning family of group `group_index` with idle members in `pool_slot`,
    // or 0. Only used when the hire lands in the group's owner signature.
    uint64_t owning_family_for_owner_hire(int32_t group_index,
                                          int32_t pool_slot) const;
    void release_unstaffable_family_ownership(int32_t family_index);
    void record_person_deaths_for_family(int32_t cohort_slot,
                                         uint64_t family_handle,
                                         int64_t people_before,
                                         int64_t deaths);
    // Clamp derived employment/basis fields so membership edges always satisfy
    // the PKEC restore invariants even if attribution briefly overshoots.
    static void sanitize_family_membership_edge(FamilyMembershipEdge &edge);
    // Clamp ownership shares to the surviving building count and owner-slot
    // capacity. Liquidation and demolition shrink a group after the shares were
    // granted, so without this the PKEC restore invariants can reject a save.
    void sanitize_family_ownership_edges();
    void absorb_family_households();
    int64_t family_household_target_people(int64_t owner_slots) const;
    int64_t family_household_people_for_slot(int32_t slot,
                                             int64_t owner_slots) const;
    int64_t family_owned_owner_slots_in_cell(int32_t family_index,
                                             int32_t cell) const;
    void add_family_household_people(uint64_t family_handle, int32_t slot,
                                     int64_t take);
    int64_t family_people_on_slot(int32_t slot) const;
    void update_family_employment_attribution();
    void attribute_family_owner_employment_for_cell(int32_t cell);
    int32_t create_family_for_building(
        int32_t cell, int32_t building_index, int64_t founders,
        int64_t filled_owner, bool allow_small_starter = false,
        const FamilyFoundingIdentity *identity = nullptr);
    void review_family_milestone(int32_t cell);
    int64_t family_milestone_hash() const;
    int64_t family_founding_founders_for_group(int32_t cell,
                                               int32_t group_index) const;
    int32_t build_family_founding_candidates(
        int32_t cell, int32_t milestone_index,
        std::vector<FamilyFoundingCandidate> &out) const;
    bool resolve_family_founding_offer(FamilyFoundingOffer &offer,
                                       int32_t choice_index);
    bool family_founding_player_choice(int32_t cell) const;
    int32_t family_founding_auto_choice(const FamilyFoundingOffer &offer) const;
    const char *family_founding_choice_error(size_t offer_row,
        int64_t generation, int32_t choice) const;
    void publish_family_founding_choice_result(int64_t sequence, int64_t day, const char *reason);
    void apply_due_family_founding_choices();
    void rebuild_family_founding_offer_index();
    int32_t family_founding_offer_for_cell(int32_t cell);
    void prune_family_founding_effects();
    void clear_family_founding_state();
    bool write_family_founding_save_records(int32_t budget,
                                            std::vector<uint8_t> &payload);
    bool read_family_founding_save_records(const std::vector<uint8_t> &bytes,
                                           size_t &cursor, uint32_t records,
                                           std::string &error);
    bool validate_restored_family_founding(std::string &error) const;
    void append_family_founding_hash(uint64_t &hash) const;
    int32_t family_founding_effect_for(int64_t stable_id) const;
    int32_t roll_core_family_traits(uint64_t stable_id, int32_t tech_cell,
                                    int32_t origin_cell,
                                    std::vector<int32_t> &trait_ids,
                                    std::vector<int32_t> &strengths) const;
    int32_t roll_random_pool_family_effect(
        uint64_t stable_id, int32_t tech_cell,
        const std::vector<int32_t> &owned_sorted,
        const std::vector<int32_t> &avoid) const;
    void review_family_lifecycle();
    void assign_core_family_traits(int32_t family_index);
    int32_t resolve_family_trait_command(int32_t operation, uint64_t handle,
        const std::string &key, int32_t strength, int64_t day, std::string &error) const;
    void apply_due_family_trait_commands();
    void rebuild_family_influences(bool rebuild_derived = true);
    void reconcile_family_branch_effects(uint64_t branch_handle,
                                         bool submit_changes);
    void clear_family_branch_effects(uint64_t branch_handle);
    void rebuild_family_effect_binding_index();
    void add_family_effect_binding(FamilyEffectBinding binding);
    void remove_family_effect_binding(size_t index);
    int64_t family_effect_metric_revision(int32_t phase) const;
    bool publish_family_effect_metrics(const FamilyEffectBinding &binding,
                                       int64_t revision,
                                       const MetricMask &requested_mask);
    void refresh_family_effect_metrics_for_branch(uint64_t branch_handle,
                                                  int64_t revision,
                                                  const MetricMask &requested_mask);
    void refresh_family_effect_metrics_for_cell(int32_t cell,
                                                int64_t revision,
                                                const MetricMask &requested_mask);
    int32_t family_trait_behavior_factor_q16(uint64_t family_handle,
                                             int32_t axis,
                                             int32_t selector_kind,
                                             int32_t selector_id,
                                             int32_t cell = -1) const;
    int32_t family_behavior_score_term_q16(uint64_t family_handle,
                                           int32_t cell,
                                           int32_t score_term) const;
    int32_t family_purchase_pay_factor_q16(int32_t cohort_slot) const;
    int32_t family_free_building_type_id(const Command &cmd) const;
    void fill_family_behavior_metrics(int32_t family_index, int32_t branch,
                                      int32_t cell, int64_t *metrics,
                                      int32_t metric_count,
                                      const MetricMask &metric_mask =
                                          MetricMask::all()) const;
    bool evaluate_family_behavior_conditions(int32_t edge,
                                             const int64_t *metrics,
                                             int32_t metric_count) const;
    int32_t building_local_resource_abundance_q16(int32_t cell,
                                                  int32_t type_id) const;
    int32_t cell_profession_share_q16(int32_t cell,
                                      int32_t profession_id) const;
    bool family_trait_technology_unlocked(int32_t trait_id, int32_t cell) const;
    bool family_effect_technology_unlocked(int32_t effect_id, int32_t cell) const;
    bool family_trait_origin_gates_allow(int32_t trait_id, int32_t origin_cell) const;
    bool family_trait_context_allows(int32_t trait_id, int32_t family_index) const;
    void collect_family_effect_target_cells(
        int32_t source_cell, int32_t selector_kind,
        std::vector<int32_t> &out_cells,
        const std::string &definition_key = std::string(),
        int32_t prestige_level = 1) const;

    // Save candidate validation and decoding.
    bool decode_restore_chunk(const std::vector<uint8_t> &bytes, std::string &error);
    bool decode_restore_header(const std::vector<uint8_t> &bytes, size_t &cursor,
                               uint16_t schema, uint32_t records, std::string &error);
    bool begin_restore_internal(std::string &error);
    bool end_restore_internal(std::string &error);
    // Clears live SoA into an empty candidate rebuild surface. Must only run
    // after apply_ecp2_authority has captured a rollback backup (or from the
    // explicit PKEC migrate helper).
    void prepare_restore_candidate_scratch();
    bool apply_ecp2_authority_internal(const RuntimeEconomyEcp2State &in,
                                       std::string &error);
    void set_restore_rejected_reason(const std::string &reason);
    bool validate_ecp2_candidate(const RuntimeEconomyEcp2State &in,
                                 std::string &error) const;
    bool validate_restored_committed_snapshot(std::string &error) const;

    bool reserve_family_expedition_payload_slots(
        int32_t expedition, uint32_t begin, uint32_t end, bool stop_on_failure);

    bool decode_restore_family_tables(
        const std::vector<uint8_t> &bytes, size_t &cursor, uint16_t schema,
        uint16_t section, uint32_t records, std::string &error);
