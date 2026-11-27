bool RuntimeEconomyPodAuthority::is_owned_core_opcode(
        int32_t opcode) noexcept {
    return opcode >= NativeEconomyRuntime::COMMAND_TRANSFER_TO_COHORT &&
        opcode <= NativeEconomyRuntime::COMMAND_FAMILY_SET_SPLIT_POLICY;
}

bool RuntimeEconomyPodAuthority::is_owned_heavy_pod_opcode(
        int32_t opcode) noexcept {
    return opcode == NativeEconomyRuntime::COMMAND_BUILD ||
        (opcode >= NativeEconomyRuntime::COMMAND_FAMILY_FREE_BUILDING &&
         opcode <= NativeEconomyRuntime::COMMAND_SETTLE_FAMILY_EXPEDITION) ||
        opcode == NativeEconomyRuntime::COMMAND_BUILD_CANAL ||
        opcode == NativeEconomyRuntime::COMMAND_FAMILY_ABSORB_ANONYMOUS;
}

bool RuntimeEconomyPodAuthority::try_apply_owned_core_command(
        const RuntimeEconomyPodCommand &command, std::string &error,
        int64_t &settled_out) noexcept {
    error.clear();
    settled_out = 0;
    if (!is_owned_core_opcode(command.opcode)) {
        error = "economy_pod_owned_core_opcode_unsupported";
        return false;
    }
    if (!state_initialized()) {
        error = "economy_pod_owned_core_state_uninitialized";
        return false;
    }
    if (is_owned_heavy_pod_opcode(command.opcode)) {
        settled_out = 0;
        return true;
    }
    auto sat_add = [](int64_t a, int64_t b) -> int64_t {
        if (b > 0 && a > std::numeric_limits<int64_t>::max() - b)
            return std::numeric_limits<int64_t>::max();
        if (b < 0 && a < std::numeric_limits<int64_t>::min() - b)
            return std::numeric_limits<int64_t>::min();
        return a + b;
    };
    RuntimeEconomyPopulationStore &population = _state.population;
    RuntimeEconomyMarketStore &market = _state.market;
    RuntimeEconomyFamilyStore &families = _state.families;
    RuntimeEconomyBuildingStore &buildings = _state.buildings;
    const uint64_t target_handle = command.target_cohort != 0
                                         ? command.target_cohort
                                         : command.target_building;
    switch (command.opcode) {
    case NativeEconomyRuntime::COMMAND_TRANSFER_TO_COHORT: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_ledger";
            return false;
        }
        if (slot < 0 ||
            static_cast<size_t>(slot) >= population.funds.size() ||
            static_cast<size_t>(slot) >= population.epoch_income.size()) {
            error = "economy_pod_owned_core_slot_oob";
            return false;
        }
        const int64_t amount = std::max<int64_t>(0, command.payload0);
        population.funds.write_scalar(static_cast<size_t>(slot), sat_add(
            population.funds[static_cast<size_t>(slot)], amount));
        population.epoch_income.write_scalar(static_cast<size_t>(slot), sat_add(
            population.epoch_income[static_cast<size_t>(slot)], amount));
        settled_out = amount;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_MINT_TO_COHORT: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_mint";
            return false;
        }
        if (slot < 0 ||
            static_cast<size_t>(slot) >= population.funds.size() ||
            static_cast<size_t>(slot) >= population.epoch_income.size()) {
            error = "economy_pod_owned_core_slot_oob";
            return false;
        }
        population.funds.write_scalar(static_cast<size_t>(slot), sat_add(
            population.funds[static_cast<size_t>(slot)], command.payload0));
        population.epoch_income.write_scalar(static_cast<size_t>(slot), sat_add(
            population.epoch_income[static_cast<size_t>(slot)],
            command.payload0));
        settled_out = command.payload0;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_BURN_FROM_COHORT: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_burn";
            return false;
        }
        if (slot < 0 ||
            static_cast<size_t>(slot) >= population.funds.size() ||
            static_cast<size_t>(slot) >= population.epoch_expense.size()) {
            error = "economy_pod_owned_core_slot_oob";
            return false;
        }
        const int64_t funds =
            population.funds[static_cast<size_t>(slot)];
        const int64_t amount =
            std::min(command.payload0, std::max<int64_t>(0, funds));
        population.funds.write_scalar(static_cast<size_t>(slot), funds - amount);
        population.epoch_expense.write_scalar(static_cast<size_t>(slot), sat_add(
            population.epoch_expense[static_cast<size_t>(slot)], amount));
        settled_out = amount;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_ADD_STOCK: {
        const int32_t market_id = command.target_cell;
        const int32_t good_id = static_cast<int32_t>(command.target_country);
        if (market.market_count <= 0 || market.good_count <= 0 ||
            market_id < 0 || market_id >= market.market_count || good_id < 0 ||
            good_id >= market.good_count) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t idx = market.index(market_id, good_id);
        if (idx < 0 || static_cast<size_t>(idx) >= market.stock.size()) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t before = market.stock[static_cast<size_t>(idx)];
        market.stock.write_scalar(static_cast<size_t>(idx),
            sat_add(before, command.payload0));
        settled_out = market.stock[static_cast<size_t>(idx)] - before;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_REMOVE_STOCK: {
        const int32_t market_id = command.target_cell;
        const int32_t good_id = static_cast<int32_t>(command.target_country);
        if (market.market_count <= 0 || market.good_count <= 0 ||
            market_id < 0 || market_id >= market.market_count || good_id < 0 ||
            good_id >= market.good_count) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t idx = market.index(market_id, good_id);
        if (idx < 0 || static_cast<size_t>(idx) >= market.stock.size()) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t stock = market.stock[static_cast<size_t>(idx)];
        const int64_t amount =
            std::min(command.payload0, std::max<int64_t>(0, stock));
        market.stock.write_scalar(static_cast<size_t>(idx), stock - amount);
        settled_out = amount;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_ADD_POPULATION: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_population_adjust";
            return false;
        }
        if (slot < 0 ||
            static_cast<size_t>(slot) >= population.population.size()) {
            error = "economy_pod_owned_core_slot_oob";
            return false;
        }
        const int32_t page = slot / RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE;
        if (page < 0 ||
            static_cast<size_t>(page) >= population.page_cell.size()) {
            error = "economy_pod_owned_core_page_oob";
            return false;
        }
        const int32_t event_cell = population.page_cell[static_cast<size_t>(page)];
        const int64_t before = population.population[static_cast<size_t>(slot)];
        const int64_t after =
            std::max<int64_t>(0, sat_add(before, command.payload0));
        const int64_t actual_delta = after - before;
        population.population.write_scalar(static_cast<size_t>(slot), after);
        population.owner_employed.write_scalar(static_cast<size_t>(slot), std::clamp<int64_t>(
                population.owner_employed[static_cast<size_t>(slot)], 0,
                after));
        population.employee_employed.write_scalar(static_cast<size_t>(slot), std::clamp<int64_t>(
                population.employee_employed[static_cast<size_t>(slot)], 0,
                after - population.owner_employed[static_cast<size_t>(slot)]));
        settled_out = actual_delta;
        _state.external_population_delta =
            sat_add(_state.external_population_delta, actual_delta);
        if (after == 0) {
            RuntimeEconomyOwnedStructuralCommand structural{};
            structural.opcode = 0;
            structural.source_slot = slot;
            structural.cell = event_cell;
            if (static_cast<size_t>(slot) < population.signature_id.size())
                structural.signature = static_cast<int32_t>(
                    population.signature_id[static_cast<size_t>(slot)]);
            structural.sequence =
                static_cast<int64_t>(command.submit_order);
            _state.structural_commands.push_back(structural);
        }
        return true;
    }
    case NativeEconomyRuntime::COMMAND_MILITARY_CONVERT_COHORT: {
        // B: state-directed conversion inside one cell. payload0 = heads,
        // target_country = destination signature, payload1 = source signature,
        // target_cell = the cell. Both cohorts are resolved in THIS store, so
        // no slot id crosses an execution boundary and the move is conserved
        // inside the same cell.
        const int32_t conv_cell = command.target_cell;
        const int32_t dest_signature = static_cast<int32_t>(command.target_country);
        const int32_t source_signature = static_cast<int32_t>(command.payload1);
        if (conv_cell < 0 || dest_signature < 0 || source_signature < 0) {
            error = "military_convert_target_invalid";
            return false;
        }
        int32_t src = population.find_signature(conv_cell,
            static_cast<uint32_t>(source_signature));
        if (src < 0 || population.active[static_cast<size_t>(src)] == 0) {
            error = "military_convert_source_missing";
            return false;
        }
        const int64_t want = std::max<int64_t>(0, command.payload0);
        const int64_t available = std::max<int64_t>(0, population.population[static_cast<size_t>(src)]);
        const int64_t moved = std::min(want, available);
        if (moved <= 0) {
            error = "military_convert_source_empty";
            return false;
        }
        int32_t dst = population.find_signature(conv_cell,
            static_cast<uint32_t>(dest_signature));
        if (dst < 0) {
            dst = population.allocate_slot(conv_cell, static_cast<uint32_t>(dest_signature));
            if (dst < 0) {
                error = "military_convert_allocation_failed";
                return false;
            }
        }
        population.population.write_scalar(static_cast<size_t>(src),
            available - moved);
        population.population.write_scalar(static_cast<size_t>(dst),
            std::max<int64_t>(0, population.population[static_cast<size_t>(dst)]) + moved);
        settled_out = moved;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_MOVE_POPULATION:
    case NativeEconomyRuntime::COMMAND_CHANGE_SIGNATURE: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_structure_queue";
            return false;
        }
        const int32_t page = slot / RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE;
        if (page < 0 ||
            static_cast<size_t>(page) >= population.page_cell.size()) {
            error = "economy_pod_owned_core_page_oob";
            return false;
        }
        const int64_t requested =
            command.payload0 <= 0
                ? population.population[static_cast<size_t>(slot)]
                : command.payload0;
        RuntimeEconomyOwnedStructuralCommand structural{};
        structural.opcode = command.opcode;
        structural.source_slot = slot;
        structural.cell =
            command.opcode == NativeEconomyRuntime::COMMAND_MOVE_POPULATION
                ? command.target_cell
                : population.page_cell[static_cast<size_t>(page)];
        // CHANGE_SIGNATURE's destination signature rides payload1. The
        // project-wide target_country / target_cell lanes already carry the
        // market id, good id and destination cell, so putting a signature there
        // turned the cell into a signature and failed commit validation.
        int32_t destination_signature =
            static_cast<int32_t>(population.signature_id[static_cast<size_t>(slot)]);
        if (command.opcode == NativeEconomyRuntime::COMMAND_CHANGE_SIGNATURE) {
            destination_signature = command.payload1 > 0
                ? static_cast<int32_t>(command.payload1)
                : static_cast<int32_t>(command.target_country);
        }
        structural.signature = destination_signature;
        // The POD mirror and the live runtime do not share cohort slot ids, so
        // the source is re-resolved at commit time from (cell, source signature).
        // The funds lane is unused for a signature move and carries that id.
        structural.funds = command.opcode == NativeEconomyRuntime::COMMAND_CHANGE_SIGNATURE
            ? static_cast<int64_t>(population.signature_id[static_cast<size_t>(slot)])
            : 0;
        structural.population = requested;
        structural.sequence = static_cast<int64_t>(command.submit_order);
        _state.structural_commands.push_back(structural);
        settled_out = requested;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_TRANSFER_FROM_COHORT: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_transfer";
            return false;
        }
        if (slot < 0 ||
            static_cast<size_t>(slot) >= population.funds.size() ||
            static_cast<size_t>(slot) >= population.epoch_expense.size()) {
            error = "economy_pod_owned_core_slot_oob";
            return false;
        }
        const int64_t funds =
            population.funds[static_cast<size_t>(slot)];
        const int64_t amount =
            std::min(command.payload0, std::max<int64_t>(0, funds));
        population.funds.write_scalar(static_cast<size_t>(slot), funds - amount);
        population.epoch_expense.write_scalar(static_cast<size_t>(slot), sat_add(
            population.epoch_expense[static_cast<size_t>(slot)], amount));
        settled_out = amount;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_DEMOLISH: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_demolish";
            return false;
        }
        const int32_t cell = command.target_cell;
        const int32_t type_id = static_cast<int32_t>(command.target_country);
        const int64_t count = command.payload0;
        const int32_t page = slot / RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE;
        if (cell < 0 || cell >= market.market_count || type_id < 0 || count <= 0 ||
            page < 0 || static_cast<size_t>(page) >= population.page_cell.size() ||
            population.page_cell[static_cast<size_t>(page)] != cell) {
            error = "demolish_target_invalid";
            return false;
        }
        const int32_t signature = static_cast<int32_t>(
            population.signature_id[static_cast<size_t>(slot)]);
        const int32_t group_id =
            find_owned_building_group(buildings, cell, type_id, signature);
        if (group_id < 0 ||
            static_cast<size_t>(group_id) >= buildings.group_units.size() ||
            buildings.group_units[static_cast<size_t>(group_id)] < count) {
            error = "demolish_owned_count_insufficient";
            return false;
        }
        buildings.group_units.write_scalar(static_cast<size_t>(group_id), buildings.group_units[static_cast<size_t>(group_id)] - (count));
        settled_out = count;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_COUNTRY_GOOD_TO_MARKET: {
        const int32_t market_id = command.target_cell;
        const int32_t good_id = static_cast<int32_t>(command.target_country);
        if (market.market_count <= 0 || market.good_count <= 0 ||
            market_id < 0 || market_id >= market.market_count || good_id < 0 ||
            good_id >= market.good_count) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t idx = market.index(market_id, good_id);
        if (idx < 0 || static_cast<size_t>(idx) >= market.stock.size()) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t before = market.stock[static_cast<size_t>(idx)];
        market.stock.write_scalar(static_cast<size_t>(idx),
            sat_add(before, command.payload0));
        settled_out = market.stock[static_cast<size_t>(idx)] - before;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_MARKET_GOOD_TO_COUNTRY: {
        const int32_t market_id = command.target_cell;
        const int32_t good_id = static_cast<int32_t>(command.target_country);
        if (market.market_count <= 0 || market.good_count <= 0 ||
            market_id < 0 || market_id >= market.market_count || good_id < 0 ||
            good_id >= market.good_count) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t idx = market.index(market_id, good_id);
        if (idx < 0 || static_cast<size_t>(idx) >= market.stock.size()) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t stock = market.stock[static_cast<size_t>(idx)];
        const int64_t amount =
            std::min(command.payload0, std::max<int64_t>(0, stock));
        market.stock.write_scalar(static_cast<size_t>(idx), stock - amount);
        settled_out = amount;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_FAMILY_PURCHASE_DISCOUNT: {
        int32_t branch = -1;
        if (!owned_valid_influence_handle(families, target_handle, branch)) {
            error = "family_purchase_discount_target_invalid";
            return false;
        }
        int32_t family = -1;
        if (branch < 0 ||
            static_cast<size_t>(branch) >=
                families.influence_family_handle.size() ||
            !owned_valid_family_handle(
                families, families.influence_family_handle[static_cast<size_t>(
                                branch)],
                family)) {
            error = "family_purchase_discount_target_invalid";
            return false;
        }
        ensure_owned_family_purchase_factors(families);
        families.purchase_factor_q16[static_cast<size_t>(family)] =
            static_cast<int32_t>(
                std::clamp<int64_t>(command.payload0, 0, Q16_ONE));
        settled_out = command.payload0;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_FAMILY_SET_SPLIT_POLICY: {
        int32_t family = -1;
        int32_t branch = -1;
        if (owned_valid_family_handle(families, target_handle, family)) {
        } else if (owned_valid_influence_handle(families, target_handle,
                                                branch)) {
            if (branch < 0 ||
                static_cast<size_t>(branch) >=
                    families.influence_family_handle.size() ||
                !owned_valid_family_handle(
                    families,
                    families.influence_family_handle[static_cast<size_t>(
                        branch)],
                    family)) {
                error = "family_split_policy_target_invalid";
                return false;
            }
        } else {
            error = "family_split_policy_target_invalid";
            return false;
        }
        const uint16_t policy = static_cast<uint16_t>(command.target_cell) &
            NativeEconomyRuntime::FAMILY_FLAG_SPLIT_POLICY_MASK;
        const uint8_t weight = static_cast<uint8_t>(
            std::clamp<int64_t>(command.payload0, 0, 255));
        apply_owned_family_split_policy_flags(families, family, policy, weight);
        settled_out = command.payload0;
        return true;
    }
    default:
        error = "economy_pod_owned_core_opcode_unsupported";
        return false;
    }
}
