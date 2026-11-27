// Private command, catalog, state hash, and research operations.

    bool validate_handle(uint64_t handle, int32_t &slot) const;
    bool validate_admission_command(const Command &command,
                                    std::string &error) const;
    void push_typed_receipt(const Command &command,
                            CountryCommandReceiptCode code,
                            const std::string &reason = {});
    CountryBoundarySeal open_implicit_boundary(int64_t day);
    void close_boundary_seal();
    CountryCoreStepResult run_slice_core(int64_t requested_day);
    bool prepare_country_slice(CoreSliceContext &context);
    bool preflight_country_slice(CoreSliceContext &context);
    bool commit_country_slice(CoreSliceContext &context);
    bool report_peer_rejection(int64_t day, CountryCoreStepResult &result);
    uint64_t make_handle(int32_t slot) const;
    int64_t debit_country_cash(int64_t country_handle, int64_t requested,
                                const char *trace_stage);
    int64_t credit_country_cash(int64_t country_handle, int64_t offered,
                                const char *trace_stage);
    uint64_t begin_economy_asset_transaction(
        EconomyAssetTransaction &transaction, uint64_t request_id,
        uint32_t origin_domain, int64_t origin_epoch, int32_t origin_stage);
    void finish_economy_asset_transaction(EconomyAssetTransaction &transaction,
                                           bool completed,
                                           const char *rejection_reason = nullptr,
                                           bool conservation_failure = false);
    bool find_economy_asset_transaction(uint64_t request_id,
                                        EconomyAssetTransaction &out) const;
    int64_t complete_economy_asset_compatibility(
        const godot::Dictionary &begin);
    godot::Dictionary begin_economy_fiscal_cash_credit(
        AssetOperation operation, int64_t country_handle, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id,
        const char *invalid_reason);
    int32_t append_country(const std::string &stable_id,
                           const std::string &display_name, int64_t cash);
    int32_t tax_item_count(int32_t kind) const;
    const std::vector<int32_t> *tax_override_vector(int32_t kind) const;
    std::vector<int32_t> *tax_override_vector(int32_t kind);
    const std::vector<int32_t> *tax_mode_override_vector(int32_t kind) const;
    std::vector<int32_t> *tax_mode_override_vector(int32_t kind);
    static bool tax_assessment_mode_valid(int32_t mode);
    static bool tax_value_valid(int32_t mode, int32_t value);
    static int32_t resolved_tax_rate(const std::vector<int32_t> &defaults,
                                    const std::vector<int32_t> &overrides,
                                    int32_t country_slot, int32_t kind,
                                    int32_t item, int32_t item_count);
    static int32_t resolved_tax_mode(const std::vector<int32_t> &default_modes,
                                    const std::vector<int32_t> &mode_overrides,
                                    int32_t country_slot, int32_t kind,
                                    int32_t item, int32_t item_count);
    static ResolvedTaxPolicy resolved_tax_policy(
        const std::vector<int32_t> &defaults,
        const std::vector<int32_t> &default_modes,
        const std::vector<int32_t> &overrides,
        const std::vector<int32_t> &mode_overrides, int32_t country_slot,
        int32_t kind, int32_t item, int32_t item_count);
    static uint64_t cell_tax_policy_hash(const CellTaxPolicy &policy);
    uint32_t intern_cell_tax_policy(const CellTaxPolicy &policy);
    void release_cell_tax_policy(uint32_t policy_id);
    void rebuild_cell_tax_policy_intern();
    const CellTaxPolicy &cell_tax_policy(uint32_t policy_id) const;
    const std::vector<std::string> &tax_item_ids(int32_t kind) const;
    int32_t tax_item_index(int32_t kind, const std::string &stable_id) const;
    void rebuild_cell_csr();
    void publish_report(const char *stage, int64_t day, double preflight_ms,
                        double apply_ms, double publish_ms, int32_t changed_cells,
                        int32_t changed_countries, bool published, const std::string &reason = {});
    void push_event(Event event);
    uint64_t catalog_hash() const;
    uint64_t catalog_hash_v3() const;
    uint64_t compute_state_hash() const;
    struct ReferenceHashes {
        uint64_t identity = 0;
        uint64_t territory = 0;
        uint64_t treasury = 0;
        uint64_t technology = 0;
        uint64_t research = 0;
        uint64_t signals = 0;
        uint64_t tax = 0;
        uint64_t effect = 0;
    };
    struct ReferenceFrame {
        uint64_t frame_id = 0;
        uint64_t boundary_id = 0;
        uint32_t continuation_index = 0;
        int64_t day = -1;
        std::string stage;
        bool semantic_commit = false;
        bool day_barrier = false;
        uint64_t catalog_hash = 0;
        uint64_t technology_catalog_hash = 0;
        uint64_t command_watermark = 0;
        uint64_t command_hash = 0;
        uint64_t command_count = 0;
        uint64_t business_state_hash = 0;
        ReferenceHashes hashes;
        uint64_t generation = 0;
        uint64_t territory_generation = 0;
        uint64_t research_generation = 0;
        uint64_t tax_generation = 0;
        uint64_t visual_generation = 0;
        int64_t first_event_id = 0;
        int64_t last_event_id = 0;
        uint64_t effect_intent_count = 0;
        uint64_t effect_ack_count = 0;
    };
    ReferenceHashes compute_reference_hashes() const;
    uint64_t reference_command_hash(const std::vector<Command> &commands) const;
    void begin_reference_boundary(int64_t day);
    void record_reference_frame(const char *stage, int64_t day,
                                bool semantic_commit, bool day_barrier,
                                uint64_t command_hash = 0,
                                uint64_t command_count = 0,
                                int64_t first_event_id = 0);
    void record_direct_reference_frame(const char *stage);
    bool encode_save(std::vector<uint8_t> &out, std::string &error) const;
    bool decode_save(const std::vector<uint8_t> &bytes, std::string &error);
    bool decode_save_in_place(const std::vector<uint8_t> &bytes,
                              std::string &error);
    bool restore_core_checkpoint_in_place(
        const CountryCoreCheckpoint &checkpoint, std::string &error);
    void initialize_country_research(int32_t slot);
    void rebuild_pending_activation_index() const;
    // FULL/PROBE diagnostics validate the transient activation index against
    // the authoritative pending bitset.  A mismatch must fall back to the
    // deterministic technology scan for the current day.
    bool validate_pending_activation_index() const;
    void insert_pending_activation(int32_t slot, int32_t technology);
    void erase_pending_activation(int32_t slot, int32_t technology);
    bool country_has_research_work(int32_t slot) const;
    void rebuild_research_active_index();
    void rebuild_discovery_dependents();
    void refresh_discovery_for_completed(
        int32_t slot, const std::vector<int32_t> &completed);
    void refresh_discovery(int32_t slot);
    bool prerequisites_met(int32_t slot, int32_t technology) const;
    bool prerequisites_met(const std::vector<uint64_t> &completed, int32_t slot,
                           int32_t technology) const;
    bool era_entry_met(const std::vector<uint64_t> &completed, int32_t slot,
                       int32_t technology) const;
    bool research_condition_met(int32_t slot, int32_t technology) const;
    bool research_condition_met(const std::vector<uint64_t> &completed,
                                const std::vector<uint64_t> &signals,
                                const std::vector<std::vector<SignalEvidence>> &evidence,
                                int32_t slot, int32_t technology) const;
    bool reveal_condition_met(int32_t slot, int32_t technology) const;
    void refresh_discovery_for_technology(int32_t slot, int32_t technology);
    void refresh_discovery_for_signal(int32_t slot, int32_t signal);
    bool signal_present(const std::vector<uint64_t> &signals, int32_t slot,
                        int32_t signal) const;
    int32_t signal_count(int32_t slot, int32_t signal) const;
    int32_t signal_count(const std::vector<std::vector<SignalEvidence>> &evidence,
                         int32_t slot, int32_t signal) const;
    static SignalEvidence *find_signal_evidence(std::vector<SignalEvidence> &entries,
                                                int32_t signal);
    static const SignalEvidence *find_signal_evidence(
        const std::vector<SignalEvidence> &entries, int32_t signal);
    int64_t effective_research_cost(
        int32_t slot, int32_t technology,
        const CountryPeerContext *peer_context = nullptr) const;
    void ensure_research_modifier_cache(
        int32_t slot,
        const CountryPeerContext *peer_context = nullptr) const;
    // Sparse progress may exceed catalog base cost when country.research.cost_factor
    // is above 1.0. Restore validation must accept any value that effective cost
    // could legally reach under the ModifierCatalog clamp ceiling.
    int64_t max_storable_research_progress(int32_t technology) const;
    bool finalize_research_head_if_complete(int32_t slot, int32_t domain,
                                            int64_t day_index,
                                            bool use_pending_queue,
                                            CountryPeerContext *peer_context = nullptr);
    int64_t progress_for(int32_t slot, int32_t technology) const;
    void set_progress(int32_t slot, int32_t technology, int64_t value);
    int32_t run_research_day(
        int64_t day_index, const CountryPeerContext *peer_context = nullptr,
        CountryPeerContext *out_peer_context = nullptr);
    bool ensure_technology_effect_instance(
        int32_t slot, int32_t technology, int64_t day_index,
        CountryPeerContext &peer_context);
    bool ack_chain_due(
        int64_t day_index,
        const CountryPeerContext *peer_context = nullptr) const;
    CountryPeerTechnologyState *find_peer_technology_state(
        CountryPeerContext &context, int32_t slot, int32_t technology);
    const CountryPeerTechnologyState *find_peer_technology_state(
        const CountryPeerContext &context, int32_t slot,
        int32_t technology) const;
    CountryPeerTechnologyState &ensure_peer_technology_state(
        CountryPeerContext &context, int32_t slot, int32_t technology);
    CountryPeerResult apply_peer_intent(CountryPeerContext &context,
                                         const CountryPeerIntent &intent);
    CountryPeerResult execute_peer_intent_main_thread(
        const CountryPeerIntent &intent,
        bool validate_local_identity = true);
    void apply_peer_result_to_context(CountryPeerContext &context,
                                      const CountryPeerResult &result);
    bool peer_result_identity_matches(const CountryPeerIntent &intent,
                                      const CountryPeerResult &result,
                                      std::string &error) const;
    void remember_peer_rejection(const CountryPeerResult &result);
    void clear_peer_rejections_for_retry(const CountryPeerIntent &intent);
    bool peer_rejection_blocks_activation(int32_t slot, int32_t technology,
                                          int64_t day) const;
    bool peer_rejection_needs_service(int64_t day) const;
    void mark_peer_rejections_reported(int64_t day);
    bool retry_peer_rejections(int64_t day, CountryPeerContext &context);
    void clear_peer_protocol_state();
    CountryPeerIntent make_peer_intent(
        const CountryPeerContext &context, CountryPeerIntentCode opcode,
        int32_t slot, int32_t technology, int64_t day_index) const;
