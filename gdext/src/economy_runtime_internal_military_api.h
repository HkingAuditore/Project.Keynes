// Published market and cell views for the military bridge.

    // ---- NativeEconomyRuntime military read view
    // Narrow, allocation-free reads the Military bridge uses to build
    // MilitaryWorldDigest (world_ext_military.cpp). Owned by the military
    // bridge owner; the implementation lives in
    // economy_runtime_military_view.cpp. Nothing here mutates economy state.
    //
    // Per-cell committed view, filled from the bound population SoA without
    // building any Godot value. Every lane is resized to `cell_count()`.
    using MilitaryCellView = EconomyMilitaryCellView;
    void military_read_cell_view(MilitaryCellView &out, int32_t good_count = 0) const;
    bool military_read_state_buildings(std::vector<int32_t> &out_cells,
        std::vector<int32_t> &out_type_ids, std::vector<int32_t> &out_state_roles,
        std::vector<int64_t> &out_units) const;
    // Market sellable stock and retail price for one good across every live
    // market, sparse. `sellable` (GOODS_SCALE) already excludes the merchant
    // operating floor; `price` is MONEY_SCALE per 1.0 good.
    void military_read_market(int32_t good, std::vector<int32_t> &out_cells,
                              std::vector<int64_t> &out_sellable,
                              std::vector<int64_t> &out_price, std::vector<uint8_t> &out_stocked) const;
    void military_read_equipment_production(const std::vector<int32_t> &cells,
        const std::vector<uint8_t> &equipment, std::vector<uint8_t> &out) const;
    // Dense soldier / unemployed profession ids (resolved from the profession
    // catalog; -1 when the catalog predates the military content).
    int32_t military_soldier_profession();
    int32_t military_unemployed_profession() const { return _unemployed_profession_id; }
    int32_t military_merchant_profession() const { return _merchant_profession_id; }
    // Per-head daily living cost of the soldier plan in MONEY_SCALE, excluding
    // the two ration needs Military supplies in kind (design §9.6).
    int64_t military_soldier_living_cost(int32_t country_slot) const;
    // Cohort handle for (cell, signature) / (cell, profession, any ethnicity);
    // 0 when no live cohort matches. Used to route CHANGE_SIGNATURE and
    // ADD_POPULATION intents.
    uint64_t military_cohort_handle(int32_t cell, int32_t signature) const;
    uint64_t military_cohort_handle_any_ethnicity(int32_t cell,
                                                  int32_t profession_id) const;
    // Dense profession rows of the province catalog. The levy path enumerates
    // them to decide which cohorts may be drafted (design §5.4).
    int32_t profession_count() const {
        return static_cast<int32_t>(_profession_ids.size());
    }
    // First live cohort in `cell` whose profession is one of `professions`
    // (ascending profession order, then lowest ethnicity). 0 when none.
    uint64_t military_cohort_handle_from_professions(int32_t cell,
                                                     const int32_t *professions,
                                                     int32_t count) const;
    // Total population still alive in the cell's soldier cohorts (0 = none).
    int64_t military_soldier_heads(int32_t cell) const;
    // Ethnicity of the signature a cohort handle names (-1 when stale). A
    // cohort transition must keep it so (profession, ethnicity) stays paired.
    // Signature id a cohort handle names (-1 when stale); the B opcode names
    // cohorts by signature so no slot id crosses an execution boundary.
    int32_t military_cohort_signature(uint64_t handle) const;
    int32_t military_cohort_ethnicity(uint64_t handle) const;
    // Destination signature for a cohort transition, resolved by THIS runtime's
    // own signature table: the ethnicity of the cell's cohort of `profession`,
    // else the ethnicity of any live cohort in the cell, else ethnicity 0.
    // Callers must never invent the id from a profession index.
    int32_t military_signature_for_cell_ethnicity(int32_t cell, int32_t profession) const;    // Diagnostics: how many (profession, ethnicity) signatures this catalog interns.
    int32_t military_signature_count() const { return static_cast<int32_t>(_signatures.size()); }
    // Signature id for (profession, ethnicity); -1 when the pair has no plan.
    int32_t military_signature_for(int32_t profession_id, int32_t ethnicity_id) const {
        return signature_for_profession_ethnicity(profession_id, ethnicity_id);
    }
    // Cash-neutral compatibility receipt: fiscal reserve debits the treasury
    // and collect credits it back. Returns the amount processed, not burned.
    int64_t military_collect_cash(int64_t country_handle, int64_t amount);
    // True while Economy can queue near-cash commands (no open epoch, not
    // saving/restoring, not faulted).
    bool military_command_window_open() const;
    // Queued economy commands with `effective_day <= day`. Lets the bridge tell
    // "not executed yet" apart from "rejected at execution".
    bool military_purchase_receipt(int64_t sequence, int64_t &quantity, int64_t &cash) const;
    int32_t military_queued_commands_through(int64_t day) const;
