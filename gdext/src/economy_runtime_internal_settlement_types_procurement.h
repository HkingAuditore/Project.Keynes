// Government research and era procurement continuation and settlement.

    // Resumable government research procurement state. These vectors are
    // epoch-local continuation data: candidate ordering and country budget
    // decisions are captured once, then consumed in stable cursor order.
    std::vector<CountryResearchProcurementCandidate>
        _country_research_procurement_candidates;
    std::vector<int64_t> _country_research_procurement_budgets;
    std::vector<int64_t> _country_research_procurement_remaining;
    std::vector<uint8_t> _country_research_procurement_enabled;
    size_t _country_research_procurement_cursor = 0;
    int32_t _country_research_procurement_phase = 0;
    bool _country_research_procurement_initialized = false;
    bool _country_research_procurement_done = false;
    int64_t _country_research_procurement_slices = 0;
    int64_t _country_research_procurement_transactions = 0;
    int64_t _country_research_procurement_rejections = 0;
    CountryResearchProcurementContinuation _country_research_procurement_continuation;
    FamilyExpeditionProcurementContinuation
        _family_expedition_procurement_continuation;
    // Cancelled preparations whose Country leg was already in flight. The
    // Country side commits that leg regardless, so the matching merchant
    // credit (market purchase) or market return (treasury transfer) must still
    // run once the terminal arrives.
    std::vector<FamilyExpeditionProcurementContinuation>
        _family_expedition_procurement_orphans;
    std::unordered_map<int32_t, FamilyExpeditionProcurementRejection>
        _family_expedition_procurement_rejections;
    // National procurement budgets and era purchases continue through ECP2.
    struct EraProcurementLine {
        int32_t good = -1;
        int64_t required = 0;
        int64_t purchased_total = 0;
    };
    struct EconomyProcurementState {
        uint64_t country_handle = 0;
        bool policy_enabled = false;
        int32_t treasury_share_bp = 0;
        int32_t research_share_bp = 0;
        // Shares of other_daily for era and colonization channels. -1 keeps
        // the legacy split when both channels have demand; 0 pauses a channel.
        int32_t era_share_bp = -1;
        int32_t colonization_share_bp = -1;
        bool era_active = false;
        std::vector<EraProcurementLine> era_goods;
        // Frozen at epoch begin (MONEY_SCALE per day).
        int64_t national_daily = 0;
        int64_t research_daily = 0;
        int64_t other_daily = 0;
        int64_t era_daily = 0;
        int64_t colonization_daily = 0;
        // Colonization allowance refilled per day, capped at one epoch.
        int64_t colonization_allowance = 0;
        int64_t colonization_allowance_day = -1;
        int64_t era_cash_spent_total = 0;
        int64_t era_cash_epoch = 0;
        int64_t era_last_epoch_cash = 0;
        int64_t research_cash_epoch = 0;
        int64_t research_cash_last_epoch = 0;
        int64_t colonization_cash_epoch = 0;
        int64_t colonization_cash_last_epoch = 0;
    };
    struct PendingProcurementUpdate {
        int32_t kind = 0; // 1=policy, 2=era target
        uint64_t country_handle = 0;
        bool flag = false;
        int32_t treasury_share_bp = 0;
        int32_t research_share_bp = 0;
        int32_t era_share_bp = -1;
        int32_t colonization_share_bp = -1;
        std::vector<int32_t> goods;
        std::vector<int64_t> quantities;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        uint64_t order = 0;
    };
    struct ProcurementInbox {
        std::mutex mutex;
        std::vector<PendingProcurementUpdate> updates;
        uint64_t next_order = 1;
    };
    std::unique_ptr<ProcurementInbox> _procurement_inbox =
        std::make_unique<ProcurementInbox>();
    // Owner-thread state keyed by generation-safe country handle.
    std::map<uint64_t, EconomyProcurementState> _country_procurement;
    // Research cash per day frozen at epoch open for every country slot: an
    // enabled policy's research share, the profile default shares when the
    // country never sent a policy, 0 when its policy is disabled.
    std::vector<int64_t> _epoch_research_daily;
    int32_t _procurement_default_treasury_share_bp = 200;
    int32_t _procurement_default_research_share_bp = 5000;
    // Monotone trade-order counters indexed by country slot and
    // stamped with the handle that owns the slot.
    std::vector<std::pair<uint64_t, int64_t>> _country_trade_orders_by_slot;
    struct EraProcurementCandidate {
        int32_t country = -1;
        int32_t line = -1;
        int32_t good = -1;
        int32_t market = -1;
        int64_t price = 0;
    };
    struct EraProcurementContinuation {
        bool active = false;
        int32_t phase = 0; // 1=country leg, 4=market/merchant apply
        int32_t country = -1;
        int32_t line = -1;
        int32_t market = -1;
        int32_t good = -1;
        int64_t quantity = 0;
        int64_t cash = 0;
        uint64_t transaction_id = 0;
        uint64_t session_epoch = 0;
        uint64_t country_generation = 0;
        uint64_t peer_generation = 0;
        uint64_t pending_request_id = 0;
        bool host_peer = false;
        bool market_applied = false;
        int64_t merchant_population = 0;
        std::vector<int32_t> living_merchants;
        std::vector<int64_t> merchant_weights;
        std::string last_error;
    };
    std::vector<EraProcurementCandidate> _era_procurement_candidates;
    std::vector<int64_t> _era_procurement_budgets;     // per epoch country
    std::vector<int64_t> _era_procurement_remaining;   // per (country,line) flattened
    std::vector<int32_t> _era_procurement_line_offsets; // per epoch country +1
    std::vector<uint64_t> _era_procurement_handles;    // per epoch country
    size_t _era_procurement_cursor = 0;
    bool _era_procurement_initialized = false;
    bool _era_procurement_done = false;
    int64_t _era_procurement_orders = 0;
    int64_t _era_procurement_rejections = 0;
    EraProcurementContinuation _era_procurement_continuation;
    std::vector<std::pair<uint64_t, int64_t>> _epoch_era_demand_by_cell;
    std::vector<std::pair<uint64_t, int64_t>> _epoch_era_demand_by_market;
    void apply_pending_procurement_updates(int64_t day_index);
    void freeze_epoch_procurement_budgets();
    void refresh_epoch_era_demand();
    void reset_era_procurement_epoch();
    void clear_procurement_runtime_state(bool clear_pending);
    EconomyProcurementState *procurement_state_for_slot(int32_t country);
    const EconomyProcurementState *procurement_state_for_slot(int32_t country) const;
    // Country research demand plus the frozen per-day research budget.
    bool research_procurement_policy_for(int32_t country, bool &enabled,
                                         int64_t &daily_budget,
                                         int64_t &remaining_points) const;
    // -1 = no national policy (legacy behaviour); otherwise remaining cash
    // allowance for colonization procurement today.
    int64_t colonization_procurement_allowance(uint64_t country_handle, int64_t day);
    // The epoch freeze only grants the channel to countries that already had a
    // preparing party at the boundary; a party created mid-epoch repairs the
    // missing budget here instead of being refused until the next epoch.
    void ensure_epoch_colonization_budget(uint64_t country_handle);
    void consume_colonization_procurement_allowance(uint64_t country_handle,
                                                    int64_t cash);
    void note_procurement_cash(uint64_t country_handle, int32_t kind, int64_t cash);
    void note_trade_order_countries(int32_t source_cell, int32_t destination_cell);
    bool run_government_era_procurement(std::string &error);
    bool advance_era_procurement(EraProcurementContinuation &c, std::string &error);
    bool era_procurement_parked() const {
        return _era_procurement_continuation.active &&
            _era_procurement_continuation.pending_request_id != 0;
    }
