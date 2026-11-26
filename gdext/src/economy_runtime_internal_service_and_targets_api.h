// State services, military personnel, and targeted effect and lineage queries.

    // ─── Military voucher: state service professions / state buildings ───────
    // Publishes the per-cell military ration satisfaction Military owns. Needs
    // listed in a profession's `state_supplied_need_ids` never enter market
    // purchase; their satisfaction is set from these Q16 values. Each call is
    // the whole day's set: cells absent from `cells` read 1.0, so a world
    // without soldiers is unchanged. Returns the number of cells written.
    int32_t set_military_ration_satisfaction(
        const std::vector<int32_t> &cells, const std::vector<int32_t> &q16);
    // Military-owned per-cell garrison headcount for suppression odds. Public
    // like the ration seam: Military pushes it through economy_api and never
    // touches the runtime layout.
    int32_t set_military_cell_garrison(const std::vector<int32_t> &cells,
                                       const std::vector<int32_t> &heads);
    // Player-facing rebellion odds. `action` is 0 concede / 1 bribe / 2 repress /
    // 3 ignore / 4 amnesty / 5 abandon; `spend_bp` is the share of treasury the
    // player is committing (basis points). Returns p_success_q16, cost_bp and the
    // additive terms so the UI and the resolution use one formula.
    godot::Dictionary mobilization_odds(int32_t cell, int32_t profession,
                                        int32_t action, int64_t spend_bp) const;
    // Applies an already-rolled outcome. Called at the paused narrative boundary;
    // it only mutates the sparse row and never touches conserved ledgers.
    bool apply_mobilization_result(int32_t cell, int32_t profession,
                                   int32_t action, bool success);
    godot::Dictionary resolve_player_mobilization(const godot::Dictionary &choice);
    // Convenience read used by the ration path and by diagnostics.
    int32_t military_ration_satisfaction_q16(int32_t cell) const {
        return cell >= 0 &&
            static_cast<size_t>(cell) < _military_ration_sat_q16.size()
            ? _military_ration_sat_q16[static_cast<size_t>(cell)] : Q16_ONE;
    }
    // BEGIN army personnel lane public API (contract §1.4).
    // Military publishes the army's in-kind ration fill ratio once per day; the
    // cell overload also moves the lane to the army's current cell, which is
    // what guest consumption and the household-market kernel read. The two
    // argument form keeps the previous cell (embark cell) so a caller that only
    // has a ration cannot accidentally teleport the lane.
    void set_military_army_ration(uint64_t army_handle, int32_t ration_q16);
    void set_military_army_ration(uint64_t army_handle, int32_t ration_q16,
                                  int32_t cell);
    // Reconciliation read-out for the bridge: 0 when the army has no lane.
    int64_t military_army_population(uint64_t army_handle) const;
    int64_t military_army_funds(uint64_t army_handle) const;
    int32_t military_army_cell(uint64_t army_handle) const;
    int32_t military_army_satisfaction_q16(uint64_t army_handle) const;
    int64_t military_army_lane_population() const;
    // Feature detection for the Military bridge (army-personnel contract 2
    // §1.1/§1.2): true when this build implements opcode 33
    // (COMMAND_ARMY_SPLIT_LANES). The bridge probes it the same way it probes
    // military_army_population() so an army.split / army.transfer translation can
    // choose "the heads move" over the old "the lane stays put" behaviour.
    bool military_army_lane_split_supported() const;
    // Feature detection for opcode 34 (COMMAND_ARMY_LANE_PAY, army-pay contract
    // §3.3): true when this build pays an army lane from the treasury. The
    // Military bridge probes it before emitting ARMY_PAY so an Economy that
    // predates 34 degrades to a no-op plus a failed receipt instead of an
    // admission rejection that could take the whole POD batch down.
    bool military_army_lane_pay_supported() const;
    // END army personnel lane public API
    bool profession_is_state_service_only(int32_t profession_id) const {
        return profession_id >= 0 &&
            static_cast<size_t>(profession_id) <
                _profession_state_service_only.size() &&
            _profession_state_service_only[static_cast<size_t>(profession_id)] != 0;
    }
    bool profession_need_is_state_supplied(int32_t profession_id,
                                           int32_t stable_need) const {
        if (_state_supplied_need_columns == 0 || profession_id < 0 ||
            stable_need < 0) return false;
        const size_t index = static_cast<size_t>(profession_id) *
            _need_ids.size() + static_cast<size_t>(stable_need);
        return index < _profession_state_supplied_need_mask.size() &&
            _profession_state_supplied_need_mask[index] != 0;
    }
    // True for state-owned building types (kind 3). Excluded from investment
    // review, recovery/liquidation, loss closure, family ownership and merchant
    // lending; construction and demolition go through the state commands.
    bool building_type_is_state(int32_t type_id) const {
        return type_id >= 0 &&
            static_cast<size_t>(type_id) < _building_types.size() &&
            _building_types[static_cast<size_t>(type_id)].kind == 3;
    }
    int32_t state_owner_signature() const { return _state_owner_signature; }
    // How many of `cell`'s hex neighbours satisfy the tag (-1 = count every
    // neighbour). Reuses the selector BFS so there is exactly one definition of
    // "adjacent" in the codebase; a second adjacency walk would drift from it.
    int32_t neighbor_count_with_tag(int32_t cell, int32_t tag) const;
    // One hex neighbour from the epoch snapshot, or -1 when the snapshot or
    // direction is absent. X1-b's source-count walk needs bounded R1/R2
    // neighbour reads and a BFS for radius 3/4.
    int32_t building_neighbor(int32_t cell, int32_t direction) const;
    void collect_effect_target_cells(
        int32_t source_cell, int32_t selector_kind, int32_t param0, int32_t param1,
        std::vector<int32_t> &out_cells, uint64_t selection_salt = 0,
        EffectSelectorStats *stats = nullptr) const;

    // Expand a SOURCE SET by `depth` neighbour hops, in ONE pass.
    //
    // WHY THIS EXISTS
    //
    // The kind 14/15 fan-out used to call `collect_effect_target_cells` once PER SOURCE.
    // That function allocates and zeroes a `cells`-sized `seen` buffer on every call
    // (`economy_runtime_family_buff.cpp:2663`), so a 6400-cell country with 6400 sources
    // paid 6400 allocations of 6.4 KB -- about 41 MB of allocate-and-zero per resolve,
    // on top of the walks themselves.
    //
    // With the source cap removed (2026-10-28) that pattern went from 32 sources to
    // every tagged cell, which is what pushed one resolve past the 1 ms slice gate.
    // Sharding would have spread that cost over several steps while leaving the total
    // work O(sources x cells); this removes the per-source cost instead, so the step
    // stays bounded without needing more steps at all.
    //
    // Semantics are identical to the per-source loop: the result is the UNION of the
    // rings, deduplicated. The anchor cell is NOT included (kinds 6/7 contract).
    void dilate_cell_set(const std::vector<int32_t> &sources, int32_t depth,
                         std::vector<int32_t> &out_cells) const;
    // Resource id with the largest stock at `cell`, or -1 when the cell holds
    // no resource. Ties resolve to the lowest id so the answer is stable.
    int32_t dominant_resource_at(int32_t cell) const;
    // Stock share of dominant_resource_at(cell) in Q16, or 0 when the cell holds
    // no resource.
    int32_t dominant_resource_stock_share_q16(int32_t cell) const;
    // Good id with the largest *output* at `cell`, or -1 when the cell produces
    // nothing. Unlike dominant_resource_at() this is a flow reading: it weights
    // each building group's last_output (already net of output_factor_q16) by
    // the group's authored output mix.
    int32_t dominant_output_good_at(int32_t cell, int32_t &out_share_q16) const;
    // Country slot owning `cell` in the current epoch, or -1 when the epoch
    // index has not been rebuilt (call after an epoch has run).
    int32_t cell_country_slot(int32_t cell) const;
    // Lowest cell index owned by `country_slot`, or -1. TODO: replace with a
    // real capital / city-cell anchor once the game models one -- until then a
    // cell-targeted ideology effect is anchored on the country's first cell.
    int32_t country_anchor_cell(int32_t country_slot) const;
    // How many cells `country_slot` owns in the current epoch. Returns 0 when
    // the epoch index has not been rebuilt or the slot owns nothing.
    int32_t country_cell_count(int32_t country_slot) const;
    // `index`-th cell owned by `country_slot`, ascending by cell id, or -1.
    // Ascending order is what makes SELECTOR_OWN_TERRITORY replayable: a cap
    // always keeps the lowest cell ids.
    int32_t country_cell_at(int32_t country_slot, int32_t index) const;
    // Every cell owned by `country_slot` that carries `tag` (0-based, unlike the
    // selector's 1-based ids), ascending. No cap: X1-b must count every source,
    // while SELECTOR_OWN_TERRITORY intentionally stops at its instance budget.
    // The tag snapshot is loaded once for the whole sweep.
    void collect_own_tagged_cells(int32_t country_slot, int32_t tag,
        std::vector<int32_t> &out_cells) const;
    // Catalog-declared tag table (see target_tag.h). Called once where the
    // effect runtime is attached, so the selector never has to reach through a
    // possibly-null pointer from a const query path. Assigning here also
    // invalidates the per-epoch tag bitset, so ordering against
    // capture_country_epoch() does not matter.
    void set_target_tags(const TargetTagTable &tags);
    int32_t target_tag_count() const { return _target_tags.count(); }
    // True when `cell` satisfies `tag` in the current epoch. O(1) after the
    // first call of an epoch builds the bitset; out-of-range inputs are false.
    bool cell_has_target_tag(int32_t cell, int32_t tag) const;
    // Per-cell metric sampling for programs that have NO family behind them
    // (ideology cards today, technology effects later).
    //
    // fill_family_behavior_metrics() is family-relative, so it cannot be opened
    // to other domains as-is: it is private and every existing caller passes a
    // real family/branch. This door pins both to -1, which makes every
    // family-relative metric (ids 1..4, 15..21, 32..34) read 0 -- the correct
    // answer for "this cell has no family behind the card", not a bug.
    //
    // `out_metrics` is fully zeroed first, then only the ids selected by
    // `metric_mask` are computed, so a caller can pass the program's declared
    // mask straight from FamilyEffectMetadataPod and publish exactly the ids it
    // asked for. Metrics outside the mask stay 0.
    void sample_effect_metrics(int32_t cell, int32_t metric_count,
                               int64_t *out_metrics,
                               const MetricMask &metric_mask =
                                   MetricMask::all()) const;
