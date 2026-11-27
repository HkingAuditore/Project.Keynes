// Failure context and investment and construction diagnostics.

    // reports a reason string, and the conservation numbers next to it describe
    // a half-open epoch rather than the failure — which is how a cohort-cash
    // boundary stop used to read as a money-conservation bug in the GM panel.
    struct FatalContext {
        bool valid = false;
        std::string reason;
        std::string executed_substage;
        int32_t stage = 0;
        int32_t executed_stage = 0;
        int64_t day = 0;
        int64_t epoch_id = 0;
        int32_t command_cursor = -1;
        int32_t structural_cursor = -1;
        int32_t command_opcode = 0;
        int64_t target_handle = 0;
        int64_t subject_handle = 0;
        int64_t amount = 0;
        uint32_t d7_operation_gate_mask = 0;
        bool country_sync_writes_forbidden = false;
        bool country_worker_authoritative = false;
    };
    FatalContext _fatal_context;
    // Transient forensics for failures raised inside a stage that carries
    // neither a ledger command cursor nor a structural cursor (BUILDING_COMMIT
    // substage investment). FatalContext cannot recover a row there, so the
    // failing investment leg records itself here; fatal_context_report() emits
    // it as a nested `investment` object. Diagnostics only: never persisted,
    // hashed, restored or published into the committed view.
    struct InvestmentFatalRow {
        bool valid = false;
        // 1 = drained-sponsor branch, 2 = capital top-up branch.
        int32_t branch = 0;
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t portfolio_index = -1;
        int32_t portfolio_size = 0;
        int64_t allocated_count = 0;
        int64_t owner_population = 0;
        int64_t funding_capital = 0;
        int64_t merchant_credit = 0;
        int64_t required_capital = 0;
        int64_t carried = 0;
        int64_t correction = 0;
        int32_t sponsor_slot = -1;
        int64_t sponsor_handle = 0;
        uint64_t sponsor_family_handle = 0;
        int64_t sponsor_population = 0;
        int64_t sponsor_funds = 0;
        int32_t owner_slot = -1;
        int64_t owner_funds = 0;
        bool source_drained = false;
    };
    InvestmentFatalRow _investment_fatal_row;
    // Construction-material payment drift (funds / stock) inside
    // commit_preflighted_build_command(). Same purpose as the investment row:
    // BUILDING_COMMIT has no command cursor, so the generic fatal context cannot
    // name the building or the numbers the assertion compared.
    struct ConstructionFatalRow {
        bool valid = false;
        int32_t cell = -1;
        int32_t type_id = -1;
        int64_t allocated_count = 0;
        int64_t total_cost = 0;
        int32_t owner_slot = -1;
        int64_t owner_funds = 0;
        int64_t funding_gap = 0;
        int64_t debt_principal = 0;
        bool material_feasible = false;
        int32_t good_count = 0;
        int32_t first_good_id = -1;
        int64_t first_required = 0;
        int64_t first_stock = 0;
        int32_t portfolio_index = -1;
        int32_t portfolio_size = 0;
        std::string reason;
    };
    ConstructionFatalRow _construction_fatal_row;
    // Per-leg snapshot of the investment commit, recorded while the writes
    // happen. A drift backstop can then be diagnosed from a single player log:
    // it shows what each leg actually carried / corrected / credited and how much
    // the owner held when the material invoice was paid, without needing the
    // player's 40 MB save.
    struct InvestmentLegTrace {
        int32_t candidate = -1;
        int32_t type_id = -1;
        int64_t allocated = 0;
        bool transition = false;
        int32_t sponsor_slot = -1;
        int32_t owner_slot = -1;
        int64_t owner_population = 0;
        int64_t required_capital = 0;
        int64_t source_population_before = 0;
        int64_t source_funds_before = 0;
        int64_t carried = 0;
        int64_t correction = 0;
        int64_t credit = 0;
        int64_t owner_funds_after_move = 0;
        int64_t owner_funds_after_credit = 0;
        int64_t material_cost = -1;
        int64_t owner_funds_at_material = -1;
        bool source_drained = false;
    };
    std::vector<InvestmentLegTrace> _investment_leg_trace;
    // Set by investment_commit_portfolio() right before it pays a leg's
    // material invoice, so a construction drift can name the leg order instead
    // of only the cell.
    int32_t _construction_fatal_portfolio_index = -1;
    int32_t _construction_fatal_portfolio_size = 0;
