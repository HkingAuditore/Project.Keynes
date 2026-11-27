#include "economy_runtime_includes.inc"

namespace pk {

using namespace godot;
using namespace variant_helpers;



#define PK_RESOURCE_SCRATCH_ACCESSOR(TYPE, METHOD, COLUMN, LOCAL)              \
    std::vector<TYPE> &NativeEconomyRuntime::METHOD() noexcept {               \
        if (_resource_store_alias != nullptr)                                  \
            return _resource_store_alias->COLUMN;                              \
        return LOCAL;                                                          \
    }                                                                          \
    const std::vector<TYPE> &NativeEconomyRuntime::METHOD() const noexcept {   \
        if (_resource_store_alias != nullptr)                                  \
            return _resource_store_alias->COLUMN;                              \
        return LOCAL;                                                          \
    }

PK_RESOURCE_SCRATCH_ACCESSOR(int64_t, resource_remaining_lanes, remaining,
                             _resource_remaining)
PK_RESOURCE_SCRATCH_ACCESSOR(int64_t, resource_harvest_remaining_lanes,
                             harvest_remaining, _resource_harvest_remaining)
PK_RESOURCE_SCRATCH_ACCESSOR(int64_t, resource_delta_lanes, deltas,
                             _resource_deltas)
PK_RESOURCE_SCRATCH_ACCESSOR(uint32_t, resource_lane_generation_lanes,
                             lane_generation, _resource_lane_generation)
#undef PK_RESOURCE_SCRATCH_ACCESSOR

// Building availability/constructibility gates live in
// economy_runtime_building_production.cpp.


// Emits one gameplay fact per settled cell whose population-weighted pressure
// level actually changed. The level, not the raw composite, is the dedup key,
// so a cell drifting inside a band stays silent and the event volume per epoch
// is bounded by the rolling workset.

// Fiscal settlement implementations live in economy_runtime_fiscal.cpp.

// Building resource lane implementations live in
// economy_runtime_building_resources.cpp.

// Building graph storage implementations live in
// economy_runtime_building_storage.cpp.

// Building wage planning and labor signal updates live in
// economy_runtime_building_employment.cpp.

// Production climate capacity helpers live in
// economy_runtime_building_production.cpp.


// Building command/construction mutation implementations live in
// economy_runtime_building_construction.cpp.

bool NativeEconomyRuntime::apply_command(const Command &cmd, std::string &error) {
    int32_t slot = -1;
    int32_t event_cell = -1;
    int64_t settled_value = 0;
    std::vector<EventLeg> event_legs;
    auto add_leg = [&](int32_t field, int32_t subject_kind, int64_t subject_id,
                       int32_t key_id, int64_t before, int64_t after) {
        if (before != after && trace_detail_for_cell(event_cell)) {
            event_legs.push_back({field, subject_kind, subject_id, key_id, before, after});
        }
    };
    switch (cmd.opcode) {
        case COMMAND_MILITARY_PROCUREMENT_DEMAND:
            return retain_military_procurement_demand(cmd, error);
        case COMMAND_START_FAMILY_EXPEDITION:
        case COMMAND_CANCEL_FAMILY_EXPEDITION:
            return apply_family_expedition_player_command(cmd, error);
        case COMMAND_SETTLE_FAMILY_EXPEDITION:
            return apply_settle_family_expedition(cmd, error);
        case COMMAND_TRANSFER_TO_COHORT: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_ledger";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t country_handle = cmd.i64_1 != 0 ? cmd.i64_1
                : (_country_runtime == nullptr ? 0 : country_reads().country_handle_for_cell(event_cell));
            if (country_handle == 0) { error = "country_treasury_target_invalid"; return false; }
            const int64_t treasury_before = _country_runtime == nullptr ? 0 : country_reads().total_cash();
            const int64_t funds_before = population_store().funds[slot];
            const int64_t income_before = population_store().epoch_income[slot];
            int64_t amount = 0;
            std::string cohort_cash_error;
            if (!coordinate_country_cohort_cash(
                    slot, country_handle,
                    CountryApi::ECONOMY_ASSET_CASH_TO_COHORT,
                    std::max<int64_t>(0, cmd.i64_0), amount, cohort_cash_error)) {
                error = cohort_cash_error.empty()
                    ? "country_cohort_cash_transfer_failed" : cohort_cash_error;
                return false;
            }
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, amount, 0);
            settled_value = amount;
            add_leg(FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                    treasury_before, country_reads().total_cash());
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, population_store().funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    income_before, population_store().epoch_income[slot]);
            break;
        }
        case COMMAND_MINT_TO_COHORT: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_mint";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t funds_before = population_store().funds[slot];
            const int64_t income_before = population_store().epoch_income[slot];
            population_store().funds.write_scalar(slot, saturating_add(population_store().funds[slot], cmd.i64_0, _saturation_count), market_mutation_sink());
            population_store().epoch_income.write_scalar(slot, saturating_add(population_store().epoch_income[slot], cmd.i64_0, _saturation_count), market_mutation_sink());
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, cmd.i64_0, 0);
            _explicit_money_mint = saturating_add(_explicit_money_mint, cmd.i64_0, _saturation_count);
            settled_value = cmd.i64_0;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, population_store().funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    income_before, population_store().epoch_income[slot]);
            break;
        }
        case COMMAND_BURN_FROM_COHORT: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_burn";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, population_store().funds[slot]));
            const int64_t funds_before = population_store().funds[slot];
            const int64_t expense_before = population_store().epoch_expense[slot];
            population_store().funds.write_scalar(slot, population_store().funds[slot] - (amount), market_mutation_sink());
            population_store().epoch_expense.write_scalar(slot, saturating_add(population_store().epoch_expense[slot], amount, _saturation_count), market_mutation_sink());
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, 0, amount);
            _explicit_money_burn = saturating_add(_explicit_money_burn, amount, _saturation_count);
            settled_value = amount;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, population_store().funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    expense_before, population_store().epoch_expense[slot]);
            break;
        }
        case COMMAND_ADD_STOCK: {
            event_cell = cmd.i32_0;
            const int64_t idx = market_store().index(cmd.i32_0, cmd.i32_1);
            const int64_t stock_before = market_store().stock[idx];
            audit_touch_market_lane(static_cast<size_t>(idx));
            market_store().stock.write_scalar(idx, saturating_add(market_store().stock[idx], cmd.i64_0, _saturation_count), market_mutation_sink());
            _explicit_stock_delta = saturating_add(_explicit_stock_delta, cmd.i64_0, _saturation_count);
            settled_value = market_store().stock[idx] - stock_before;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    stock_before, market_store().stock[idx]);
            break;
        }
        case COMMAND_REMOVE_STOCK: {
            event_cell = cmd.i32_0;
            const int64_t idx = market_store().index(cmd.i32_0, cmd.i32_1);
            const int64_t stock_before = market_store().stock[idx];
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, market_store().stock[idx]));
            audit_touch_market_lane(static_cast<size_t>(idx));
            market_store().stock.write_scalar(idx, market_store().stock[idx] - (amount), market_mutation_sink());
            _explicit_stock_delta = saturating_sub(_explicit_stock_delta, amount, _saturation_count);
            settled_value = amount;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    stock_before, market_store().stock[idx]);
            break;
        }
        case COMMAND_COUNTRY_GOOD_TO_MARKET: {
            event_cell = cmd.i32_0;
            if (_country_runtime == nullptr ||
                !country_reads().valid_handle(static_cast<int64_t>(cmd.target_handle))) {
                error = "country_treasury_target_invalid";
                return false;
            }
            const int64_t index = market_store().index(cmd.i32_0, cmd.i32_1);
            const int64_t before = market_store().stock[index];
            int64_t moved = 0;
            std::string market_goods_error;
            if (!coordinate_country_market_goods(
                    cmd.i32_0, cmd.i32_1,
                    static_cast<int64_t>(cmd.target_handle),
                    CountryApi::ECONOMY_ASSET_GOOD_TO_MARKET,
                    std::max<int64_t>(0, cmd.i64_0), moved, market_goods_error)) {
                error = market_goods_error.empty()
                    ? "country_market_goods_transfer_failed" : market_goods_error;
                return false;
            }
            settled_value = moved;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    before, market_store().stock[index]);
            break;
        }
        case COMMAND_MILITARY_PURCHASE_ACK:
            _pending_commands.erase_if([&](const Command &r) {
                return r.opcode == COMMAND_MILITARY_PURCHASE_RECEIPT && r.sequence == cmd.i64_0;
            });
            return true;
        case COMMAND_MILITARY_PURCHASE: {
            for (const Command &r : _pending_commands)
                if (r.opcode == COMMAND_MILITARY_PURCHASE_RECEIPT && r.sequence == cmd.sequence) return true;
            // A purchase that already settled must never buy twice. The pending
            // receipt row only guards the window before its ACK; after the ACK a
            // replayed row (save taken between drain and commit, or a duplicate
            // batch) would otherwise charge the treasury and take market stock a
            // second time (physical-maintenance design D6). The ring is transient
            // by design: a restore replays the queue, not past settlements.
            static thread_local int64_t settled_purchases[256] = {};
            static thread_local int32_t settled_purchase_cursor = 0;
            for (int32_t i = 0; i < 256; ++i) {
                if (settled_purchases[i] == cmd.sequence) return true;
            }
            Command receipt = cmd;
            receipt.opcode = COMMAND_MILITARY_PURCHASE_RECEIPT;
            receipt.effective_day = _sample_day;
            receipt.i64_0 = receipt.i64_1 = 0;
            const int32_t cell = cmd.i32_0, good = cmd.i32_1;
            if (cell >= 0 && cell < _cell_count.get() && good >= 0 && good < market_store().good_count.get() &&
                _country_runtime && country_reads().valid_handle(cmd.target_handle) &&
                country_reads().country_handle_for_cell(cell) == static_cast<int64_t>(cmd.target_handle) &&
                local_merchants_can_receive(cell) && cmd.i64_0 > 0 && cmd.i64_1 > 0) {
                const int32_t market = market_store().cell_to_market[cell];
                const size_t lane = market_store().index(market, good);
                const int64_t price = std::max<int64_t>(1, market_store().price[lane]);
                const int32_t country = country_reads().country_slot_for_cell(cell);
                const int64_t wallet = std::min(cmd.i64_1, std::max<int64_t>(0, country_reads().cash_for_slot(country)));
                const int64_t quantity = std::min({cmd.i64_0, std::max<int64_t>(0, market_store().stock[lane]),
                    mul_div_sat(wallet, GOODS_SCALE, price, _saturation_count)});
                const int64_t cost = goods_cost(quantity, price, _saturation_count);
                if (quantity > 0 && cost > 0) {
                    int64_t paid = 0;
                    if (!coordinate_country_treasury_spend(cell, market, cmd.target_handle,
                            {good}, {0}, {quantity}, cost, paid, error)) {
                        // A merchant lane nobody lives on cannot receive the money.
                        // That is "no counterparty", i.e. a zero-fill refusal, not
                        // an economy fault: failing the command here would pause
                        // the clock for a whole-country treasury because one cell
                        // lost its merchant (physical-maintenance design S5-4).
                        if (error == "country_treasury_peer_merchant_missing") {
                            error.clear();
                            receipt.i64_0 = 0;
                            receipt.i64_1 = 0;
                        } else {
                            return false;
                        }
                    } else {
                        _explicit_stock_delta = saturating_sub(_explicit_stock_delta, quantity, _saturation_count);
                        receipt.i64_0 = quantity; receipt.i64_1 = paid;
                        const int32_t signal = ensure_market_signal_index(cell, good);
                        if (signal >= 0 && signal < static_cast<int32_t>(_epoch_nonhousehold_withdrawals.size()))
                            _epoch_nonhousehold_withdrawals[signal] += quantity;
                        settled_purchases[settled_purchase_cursor & 255] = cmd.sequence;
                        ++settled_purchase_cursor;
                    }
                }
            }
            _pending_commands.push_back(receipt);
            return true;
        }
        case COMMAND_MARKET_GOOD_TO_COUNTRY: {
            event_cell = cmd.i32_0;
            if (_country_runtime == nullptr ||
                !country_reads().valid_handle(static_cast<int64_t>(cmd.target_handle))) {
                error = "country_treasury_target_invalid";
                return false;
            }
            const int64_t index = market_store().index(cmd.i32_0, cmd.i32_1);
            const int64_t before = market_store().stock[index];
            const int64_t offered = std::min(cmd.i64_0, std::max<int64_t>(0, market_store().stock[index]));
            int64_t moved = 0;
            std::string market_goods_error;
            if (!coordinate_country_market_goods(
                    cmd.i32_0, cmd.i32_1,
                    static_cast<int64_t>(cmd.target_handle),
                    CountryApi::ECONOMY_ASSET_GOOD_FROM_MARKET,
                    offered, moved, market_goods_error)) {
                error = market_goods_error.empty()
                    ? "country_market_goods_transfer_failed" : market_goods_error;
                return false;
            }
            settled_value = moved;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    before, market_store().stock[index]);
            break;
        }
        case COMMAND_ADD_POPULATION: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_population_adjust";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t before = population_store().population[slot];
            const int64_t after = std::max<int64_t>(0, saturating_add(before, cmd.i64_0,
                                                                      _saturation_count));
            const int64_t actual_delta = after - before;
            population_store().population.write_scalar(slot, after, market_mutation_sink());
            // A negative population adjustment (for example an externally
            // issued removal) must carry its employment out of the cohort too;
            // otherwise the next POD mirror export can observe jobs belonging
            // to people who no longer exist.
            population_store().owner_employed.write_scalar(slot, std::clamp<int64_t>(
                population_store().owner_employed[slot], 0, after), market_mutation_sink());
            population_store().employee_employed.write_scalar(slot, std::clamp<int64_t>(
                population_store().employee_employed[slot], 0,
                after - population_store().owner_employed[slot]), market_mutation_sink());
            settled_value = actual_delta;
            add_leg(FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1, before, after);
            _external_population_delta = saturating_add(_external_population_delta, actual_delta,
                                                        _saturation_count);
            if (actual_delta != 0)
                _structural_touched_cells.push_back(event_cell);
            if (after == 0) {
                const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
                _structural_commands.push_back({0, slot, cell,
                                                static_cast<int32_t>(population_store().signature_id[slot]),
                                                0, 0, cmd.sequence});
            }
            break;
        }
        case COMMAND_MILITARY_CONVERT_COHORT: {
            // B (design 5.4): state-directed cohort conversion inside one cell,
            // named by signature so no slot id crosses an execution boundary.
            // It goes through the ORDINARY structural path instead of writing
            // population directly: a direct write bypassed the economy ledger's
            // slot/page bookkeeping and eventually failed
            // validate_shape_and_values() (economy_pod_ledger_shape_invalid).
            //
            // The same command can reach this switch more than once (POD plan plus
            // the epoch drain), so the sequence is deduplicated: applying it twice
            // silently converts twice as many people as Military asked for
            // (observed economy 15 vs military 12).
            static thread_local int64_t recent_seq[64] = {};
            static thread_local size_t recent_at = 0;
            const int64_t conv_sequence = cmd.sequence;
            if (conv_sequence != 0) {
                for (int64_t seen : recent_seq) {
                    if (seen == conv_sequence) {
                        settled_value = 0;
                        return true;
                    }
                }
                recent_seq[recent_at % 64] = conv_sequence;
                ++recent_at;
            }
            const int32_t conv_cell = cmd.i32_0;
            const int32_t dst_signature = cmd.i32_1;
            const int32_t src_signature = static_cast<int32_t>(cmd.i64_1);
            if (conv_cell < 0 || conv_cell >= _cell_count.get() ||
                src_signature < 0 || dst_signature < 0) {
                error = "military_convert_target_invalid";
                return false;
            }
            const int32_t conv_src = population_store().find_signature(
                conv_cell, static_cast<uint32_t>(src_signature));
            if (conv_src < 0 || population_store().active[conv_src] == 0) {
                error = "military_convert_source_missing";
                return false;
            }
            const int64_t conv_requested = std::max<int64_t>(0, cmd.i64_0);
            const int64_t conv_available =
                std::max<int64_t>(0, population_store().population[conv_src]);
            const int64_t conv_moved = std::min(conv_requested, conv_available);
            if (conv_moved <= 0) {
                error = "military_convert_source_empty";
                return false;
            }
            _structural_commands.push_back({
                COMMAND_CHANGE_SIGNATURE, conv_src, conv_cell, dst_signature,
                conv_moved, 0, cmd.sequence});
            settled_value = conv_moved;
            break;
        }
        // BEGIN army personnel lane (contract §1.2).
        case COMMAND_ARMY_EMBARK:
        case COMMAND_ARMY_DISEMBARK:
        case COMMAND_ARMY_MERGE_LANES:
        case COMMAND_ARMY_SPLIT_LANES:
        // 34 (army-pay contract §1): treasury -> lane wages, lane named by army
        // handle. Same dispatch, no cohort and no structural command.
        case COMMAND_ARMY_LANE_PAY: {
            int64_t lane_settled = 0;
            if (!apply_army_lane_command(cmd, error, lane_settled)) return false;
            settled_value = lane_settled;
            break;
        }
        // END army personnel lane
        case COMMAND_MOVE_POPULATION:
        case COMMAND_CHANGE_SIGNATURE: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_structure_queue";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t requested = cmd.i64_0 <= 0 ? population_store().population[slot] : cmd.i64_0;
            _structural_commands.push_back({cmd.opcode, slot,
                                            cmd.opcode == COMMAND_MOVE_POPULATION
                                                ? cmd.i32_0
                                                : population_store().page_cell[slot / COHORT_PAGE_SIZE],
                                            cmd.opcode == COMMAND_CHANGE_SIGNATURE
                                                ? cmd.i32_0
                                                : static_cast<int32_t>(population_store().signature_id[slot]),
                                            requested, 0, cmd.sequence});
            settled_value = requested;
            break;
        }
        case COMMAND_TRANSFER_FROM_COHORT: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_transfer";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t country_handle = cmd.i64_1 != 0 ? cmd.i64_1
                : (_country_runtime == nullptr ? 0 : country_reads().country_handle_for_cell(event_cell));
            if (country_handle == 0) { error = "country_treasury_target_invalid"; return false; }
            const int64_t offered = std::min(cmd.i64_0, std::max<int64_t>(0, population_store().funds[slot]));
            const int64_t funds_before = population_store().funds[slot];
            const int64_t treasury_before = _country_runtime == nullptr ? 0 : country_reads().total_cash();
            const int64_t expense_before = population_store().epoch_expense[slot];
            int64_t amount = 0;
            std::string cohort_cash_error;
            if (!coordinate_country_cohort_cash(
                    slot, country_handle,
                    CountryApi::ECONOMY_ASSET_CASH_FROM_COHORT,
                    offered, amount, cohort_cash_error)) {
                error = cohort_cash_error.empty()
                    ? "country_cohort_cash_transfer_failed" : cohort_cash_error;
                return false;
            }
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, 0, amount);
            settled_value = amount;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, population_store().funds[slot]);
            add_leg(FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                    treasury_before, country_reads().total_cash());
            add_leg(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    expense_before, population_store().epoch_expense[slot]);
            break;
        }
        case COMMAND_BUILD: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_build";
                return false;
            }
            return apply_build_command(cmd, slot, error);
        }
        case COMMAND_DEMOLISH: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_demolish";
                return false;
            }
            return apply_demolish_command(cmd, slot, error);
        }
        case COMMAND_FAMILY_FREE_BUILDING:
            return apply_family_free_building_reward(cmd, error);
        case COMMAND_FAMILY_POPULATION_REWARD:
            return apply_family_population_reward(cmd, error);
        case COMMAND_FAMILY_ABSORB_ANONYMOUS:
            return apply_family_absorb_anonymous(cmd, error);
        case COMMAND_FAMILY_PURCHASE_DISCOUNT:
            return apply_family_purchase_discount(cmd, error);
        case COMMAND_FAMILY_SET_SPLIT_POLICY:
            return apply_family_set_split_policy(cmd, error);
        case COMMAND_TREASURY_SPONSORED_BUILD:
            return apply_treasury_sponsored_build_command(cmd, error);
        case COMMAND_TREASURY_SPONSORED_DEMOLISH:
            return apply_treasury_sponsored_demolish_command(cmd, error);
        case COMMAND_BUILD_CANAL:
            return apply_canal_build_command(cmd, error);
        default:
            error = "unsupported_command_opcode";
            return false;
    }
    trace_append(EVENT_COMMAND_SETTLED, static_cast<int32_t>(Stage::LEDGER_APPLY),
                 event_cell, SUBJECT_COMMAND, cmd.sequence, cmd.opcode, cmd.i32_1,
                 cmd.opcode, settled_value, cmd.i64_0, cmd.i64_1,
                 event_legs.empty() ? nullptr : &event_legs);
    return true;
}

bool NativeEconomyRuntime::commit_structural(const StructuralCommand &cmd,
                                             std::string &error) {
    // BEGIN army personnel lane (contract §1.2): lane transfers own their
    // cohort-side bookkeeping but run on this same structural stage.
    if (cmd.opcode == STRUCTURAL_ARMY_EMBARK ||
        cmd.opcode == STRUCTURAL_ARMY_DISEMBARK)
        return commit_structural_army_lane(cmd, error);
    // END army personnel lane
    if (cmd.opcode == STRUCTURAL_BIRTH) {
        if (cmd.cell < 0 || cmd.cell >= _cell_count.get() || cmd.signature < 0 ||
            cmd.signature >= static_cast<int32_t>(_signatures.size()) ||
            cmd.population <= 0 || _signatures[cmd.signature].profession_id !=
                _unemployed_profession_id) {
            error = "structural_birth_target_invalid";
            return false;
        }
        const int32_t destination = population_store().allocate_slot(
            cmd.cell, static_cast<uint32_t>(cmd.signature));
        if (destination < 0) {
            error = "structural_birth_allocation_failed";
            return false;
        }
        touch_accounting_slot(destination);
        const int64_t population_before = population_store().population[destination];
        population_store().population.write_scalar(destination, saturating_add(
            population_before, cmd.population, _saturation_count), market_mutation_sink());
        apply_family_birth_attribution(destination, cmd.population);
        _structural_touched_cells.push_back(cmd.cell);
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(cmd.cell)) {
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                            static_cast<int64_t>(population_store().handle_for_slot(destination)), -1,
                            population_before, population_store().population[destination]});
        }
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), cmd.cell,
                     SUBJECT_COHORT,
                     static_cast<int64_t>(population_store().handle_for_slot(destination)),
                     cmd.signature, cmd.cell, cmd.population, 0, cmd.cell, cmd.cell,
                     legs.empty() ? nullptr : &legs);
        return true;
    }
    // A producer from another execution context (the POD queue) cannot know this
    // runtime's cohort slot ids. Re-resolve the source from the cell plus the
    // source signature it recorded in the funds lane before giving up.
    if ((cmd.source_slot < 0 ||
         cmd.source_slot >= static_cast<int32_t>(population_store().active.size()) ||
         population_store().active[cmd.source_slot] == 0) &&
        cmd.signature >= 0 && cmd.funds > 0 && cmd.funds <= 0x7fffffffLL &&
        cmd.cell >= 0 && cmd.cell < _cell_count.get()) {
        const int32_t resolved = population_store().find_signature(
            cmd.cell, static_cast<uint32_t>(cmd.funds));
        if (resolved >= 0 && population_store().active[resolved] != 0) {
            StructuralCommand repaired = cmd;
            repaired.source_slot = resolved;
            return commit_structural(repaired, error);
        }
    }
    if (cmd.source_slot < 0 || cmd.source_slot >= static_cast<int32_t>(population_store().active.size()) ||
        population_store().active[cmd.source_slot] == 0) {
        // A prior command may have consumed/released the same source. Stable
        // sequence semantics make the remaining command a deterministic no-op.
        return true;
    }
    const int32_t source = cmd.source_slot;
    const int32_t source_cell = population_store().page_cell[source / COHORT_PAGE_SIZE];
    const int64_t source_handle = static_cast<int64_t>(population_store().handle_for_slot(source));
    if (cmd.opcode == STRUCTURAL_REMOVE_EMPTY) {
        const int64_t estate_funds = population_store().funds[source];
        const int64_t country_handle = _country_runtime == nullptr ? 0
            : country_reads().country_handle_for_cell(source_cell);
        const int64_t treasury_before = _country_runtime == nullptr ? 0
            : country_reads().total_cash();
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(source_cell)) {
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                            estate_funds, 0});
            legs.push_back({FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                            treasury_before, treasury_before});
        }
        int64_t moved = 0;
        std::string cohort_cash_error;
        if (!coordinate_country_cohort_cash(
                source, country_handle,
                CountryApi::ECONOMY_ASSET_CASH_FROM_COHORT,
                estate_funds, moved, cohort_cash_error)) {
            error = cohort_cash_error.empty()
                ? "country_treasury_estate_transfer_failed" : cohort_cash_error;
            return false;
        }
        if (moved != estate_funds) {
            // Country unique-writer + closed M2 cash peer: keep the empty
            // cohort until a later day can transfer the estate. Do not burn
            // money and do not release the slot.
            if (moved == 0 &&
                (cohort_cash_error == "country_economy_operation_gate_closed" ||
                 cohort_cash_error == "country_cohort_cash_treasury_unowned" ||
                 cohort_cash_error == "country_cohort_cash_negative_balance"))
                return true;
            error = "country_treasury_estate_transfer_failed";
            return false;
        }
        _structural_funds_to_treasury = saturating_add(
            _structural_funds_to_treasury, estate_funds, _saturation_count);
        // A demography command can drain a cohort after the employment stage.
        // Remove its stale lane counts before releasing the slot; the committed
        // reconciliation pass below then clips the corresponding group fills.
        _filled_owner_jobs = saturating_sub(_filled_owner_jobs,
            std::max<int64_t>(0, population_store().owner_employed[source]), _saturation_count);
        _filled_employee_jobs = saturating_sub(_filled_employee_jobs,
            std::max<int64_t>(0, population_store().employee_employed[source]), _saturation_count);
        audit_touch_population_lane(source);
        population_store().funds.write_scalar(source, 0, market_mutation_sink());
        population_store().release_slot(source);
        population_store().reclaim_empty_pages(source_cell);
        _structural_touched_cells.push_back(source_cell);
        if (legs.size() > 1) legs[1].after = country_reads().total_cash();
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), source_cell,
                     SUBJECT_COHORT, source_handle, 0, -1,
                     0, estate_funds, source_cell, -1,
                     legs.empty() ? nullptr : &legs);
        return true;
    }
    if (cmd.cell < 0 || cmd.cell >= _cell_count.get() || cmd.signature < 0 ||
        cmd.signature >= static_cast<int32_t>(_signatures.size())) {
        ++_rejected_commands;   // unknown destination signature: drop this move, keep the day alive
        return true;
    }
    // State-service professions (soldier) are emplaced by the state, not by the
    // local job market: a barracks is a Military state building and never shows
    // up as an Economy employment seat, so requiring local availability would
    // reject every enlistment. The design (5.4) makes these posts ordinary
    // state payroll seats; the caller owns the post validation.
    const int32_t destination_profession = _signatures[cmd.signature].profession_id;
    if (!profession_is_state_service_only(destination_profession) &&
        !profession_available(cmd.cell, destination_profession, true)) {
        ++_rejected_commands;
        return true;
    }
    if (cmd.cell == source_cell &&
        cmd.signature == static_cast<int32_t>(population_store().signature_id[source])) return true;
    return move_cohort_population(source, cmd.cell, cmd.signature, cmd.population, error);
}

} // namespace pk
