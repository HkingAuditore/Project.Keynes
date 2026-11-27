#include "economy_runtime_fiscal_includes.inc"

namespace pk {

int64_t NativeEconomyRuntime::prospective_business_subsidy_request(
        int32_t cell, int32_t country) {
    if (cell < 0 || cell >= _cell_count.get() || country < 0 ||
        country + 1 >= static_cast<int32_t>(
            _epoch_country_building_type_offsets.size()) ||
        market_store().cell_to_market.size() != static_cast<size_t>(_cell_count.get()))
        return 0;
    const int32_t market = market_store().cell_to_market[static_cast<size_t>(cell)];
    if (market < 0 || market >= market_store().market_count.get()) return 0;
    const int32_t type_begin = _epoch_country_building_type_offsets[country];
    const int32_t type_end = _epoch_country_building_type_offsets[country + 1];
    const int64_t days = std::max(1, _epoch_days.get());
    int64_t best = 0;
    for (int32_t cursor = type_begin; cursor < type_end; ++cursor) {
        if (cursor < 0 || cursor >= static_cast<int32_t>(
                _epoch_country_building_type_indices.size())) continue;
        const int32_t type_id = _epoch_country_building_type_indices[cursor];
        if (type_id < 0 ||
            type_id >= static_cast<int32_t>(_building_types.size())) continue;
        const int32_t rate = frozen_tax_rate(
            cell, CountryApi::TAX_BUSINESS, type_id);
        const int32_t mode = frozen_tax_mode(
            cell, CountryApi::TAX_BUSINESS, type_id);
        if (rate >= 0) continue;
        if (mode == CountryApi::TAX_MODE_ABSOLUTE) {
            best = std::max(best, saturating_mul(
                std::abs(static_cast<int64_t>(rate)), days, _saturation_count));
            continue;
        }
        const BuildingType &type = _building_types[type_id];
        int64_t daily_eligible_cost = 0;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &input =
                _building_inputs[type.input_begin + i];
            int32_t selected = -1;
            int64_t selected_price = std::numeric_limits<int64_t>::max();
            for (int32_t candidate_index = input.candidate_begin;
                 candidate_index < input.candidate_begin + input.candidate_count;
                 ++candidate_index) {
                const InputCandidate &candidate =
                    _building_input_candidates[candidate_index];
                if (!good_input_candidate_available(cell, candidate.good_id, true))
                    continue;
                const int64_t physical = std::max<int64_t>(1, mul_div_sat(
                    input.quantity, Q16_ONE,
                    std::max<int64_t>(1, candidate.efficiency_q16),
                    _saturation_count));
                const int64_t effective_price = mul_div_sat(
                    market_store().price[market_store().index(market, candidate.good_id)],
                    physical, GOODS_SCALE, _saturation_count);
                if (effective_price < selected_price ||
                    (effective_price == selected_price &&
                     (selected < 0 || candidate.good_id <
                      _building_input_candidates[selected].good_id))) {
                    selected = candidate_index;
                    selected_price = effective_price;
                }
            }
            if (selected < 0) continue;
            const int32_t good = _building_input_candidates[selected].good_id;
            if (good < 0 || good >= static_cast<int32_t>(_good_ids.size()))
                continue;
            daily_eligible_cost = saturating_add(
                daily_eligible_cost,
                mul_div_sat(input.quantity,
                    market_store().price[market_store().index(market, good)], GOODS_SCALE,
                    _saturation_count), _saturation_count);
        }
        for (int32_t role = 0; role < type.employee_count; ++role) {
            const JobRole &job =
                _building_employee_roles[type.employee_begin + role];
            const int32_t signal = labor_signal_index(cell, job.profession_id);
            const int64_t living_floor = signal >= 0
                ? std::max(_labor_signals.base_living_cost[signal],
                    _labor_signals.role_living_cost[signal]) : 0;
            const int64_t market_quote = signal >= 0 && signal <
                    static_cast<int32_t>(_labor_signals.contract_wage_ema.size())
                ? std::max(_labor_signals.contract_wage_ema[signal],
                    _labor_signals.paid_wage_ema[signal]) : 0;
            daily_eligible_cost = saturating_add(
                daily_eligible_cost,
                saturating_mul(job.slots_per_building,
                    std::max(living_floor, market_quote), _saturation_count),
                _saturation_count);
        }
        const int64_t maintenance = daily_maintenance_cost_for_type(
            cell, type, _saturation_count);
        if (maintenance != std::numeric_limits<int64_t>::max())
            daily_eligible_cost = saturating_add(
                daily_eligible_cost, maintenance, _saturation_count);
        if (daily_eligible_cost <= 0) continue;
        best = std::max(best, mul_div_sat(
            saturating_mul(daily_eligible_cost, days, _saturation_count),
            std::abs(static_cast<int64_t>(rate)), 10000,
            _saturation_count));
    }
    return best;
}

bool NativeEconomyRuntime::prepare_fiscal_budgets(int64_t day_index,
                                                  std::string &error) {
    if (_country_runtime == nullptr) {
        error = "country_runtime_required";
        return false;
    }
    const size_t lane_count = static_cast<size_t>(_cell_count.get()) *
        ACTIVE_TAX_KIND_COUNT;
    const size_t tariff_lookup_count = static_cast<size_t>(_cell_count.get()) * 2U;
    if (_tariff_lane_index.size() != tariff_lookup_count) {
        _tariff_lane_index.assign(tariff_lookup_count, -1);
        _tariff_lane_stamp.assign(tariff_lookup_count, 0);
        _tariff_lane_generation = 0;
    }
    if (++_tariff_lane_generation == 0) {
        std::fill(_tariff_lane_stamp.begin(), _tariff_lane_stamp.end(), 0);
        _tariff_lane_generation = 1;
    }
    _tariff_epoch_cells.clear();
    _tariff_epoch_kinds.clear();
    _tariff_epoch_bases.clear();
    _tariff_epoch_assessed.clear();
    _tariff_epoch_collected.clear();
    _tariff_epoch_requests.clear();
    _tariff_epoch_reserved.clear();
    _tariff_epoch_paid.clear();
    _tariff_epoch_events.clear();
    const size_t country_tariff_count = static_cast<size_t>(
        std::max(0, _epoch_country_count)) * 2U;
    _tariff_country_requests.assign(country_tariff_count, 0);
    _tariff_country_budgets.assign(country_tariff_count, 0);
    _tariff_country_remaining.assign(country_tariff_count, 0);
    if (_fiscal_previous_requests.size() != lane_count)
        _fiscal_previous_requests.assign(lane_count, 0);
    if (_fiscal_previous_country_handles.size() !=
            static_cast<size_t>(_cell_count.get()))
        _fiscal_previous_country_handles.assign(
            static_cast<size_t>(_cell_count.get()), 0);
    if (_income_taxable_base_by_slot.size() < population_store().active.size())
        _income_taxable_base_by_slot.resize(population_store().active.size(), 0);
    if (_income_subsidy_floor_by_slot.size() < population_store().active.size())
        _income_subsidy_floor_by_slot.resize(population_store().active.size(), 0);
    const bool income_subsidy_active =
        (_epoch_negative_tax_mask & static_cast<uint8_t>(
            1U << CountryApi::TAX_INCOME)) != 0;
    if (income_subsidy_active) {
        for (const int32_t cell : _epoch_settlement_cells) {
            if (cell < 0 || cell >= _cell_count.get()) continue;
            population_store().for_each_in_cell(cell, [&](int32_t slot) {
                _income_taxable_base_by_slot[slot] = 0;
                _income_subsidy_floor_by_slot[slot] = 0;
            });
        }
    }
    const bool domestic_fiscal_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            (1U << CountryApi::TAX_INCOME) |
            (1U << CountryApi::TAX_CONSUMPTION) |
            (1U << CountryApi::TAX_BUSINESS))) != 0;
    _fiscal_reservation_requests.assign(lane_count, 0);
    _fiscal_current_requests.assign(lane_count, 0);
    _fiscal_budgets.assign(lane_count, 0);
    _fiscal_remaining.assign(lane_count, 0);
    // Settlement is hard-capped by _fiscal_remaining, so a lane that never
    // reaches the reservation pass has no budget behind it. Promising anything
    // here would let a quote offer a discount that apply_fiscal_tax cannot pay.
    _fiscal_fulfillment_q16.assign(lane_count, 0);
    _fiscal_epoch_bases.assign(lane_count, 0);
    _fiscal_epoch_assessed.assign(lane_count, 0);
    _fiscal_epoch_collected.assign(lane_count, 0);
    _fiscal_epoch_paid.assign(lane_count, 0);
    _fiscal_escrow_by_country.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    std::vector<int64_t> requested_by_country(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    // Tariff subsidy intents are the only negative tariff amounts eligible for
    // the next batch. Positive tax collected later in this epoch is therefore
    // deliberately absent from this reservation pass.
    for (size_t row = 0; row < _tariff_history.countries.size(); ++row) {
        const int32_t country = _tariff_history.countries[row];
        const int32_t kind = _tariff_history.kinds[row];
        if (country < 0 || country >= _epoch_country_count ||
            kind < CountryApi::TAX_IMPORT ||
            kind > CountryApi::TAX_EXPORT) continue;
        const size_t tariff_kind = static_cast<size_t>(
            kind - CountryApi::TAX_IMPORT);
        const size_t index = static_cast<size_t>(country) * 2U + tariff_kind;
        _tariff_country_requests[index] = saturating_add(
            _tariff_country_requests[index],
            std::max<int64_t>(0, _tariff_history.requests[row]),
            _saturation_count);
        // Per-batch fields are rebuilt by dispatch. Cumulative fields remain
        // the persistent audit history used by fiscal_snapshot and PKEC.
        _tariff_history.bases.write_scalar(row, 0, market_mutation_sink());
        _tariff_history.assessed.write_scalar(row, 0, market_mutation_sink());
        _tariff_history.collected.write_scalar(row, 0, market_mutation_sink());
        _tariff_history.requests.write_scalar(row, 0, market_mutation_sink());
        _tariff_history.reserved.write_scalar(row, 0, market_mutation_sink());
        _tariff_history.paid.write_scalar(row, 0, market_mutation_sink());
    }
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        for (int32_t tariff_kind = 0; tariff_kind < 2; ++tariff_kind) {
            const size_t index = static_cast<size_t>(country) * 2U +
                static_cast<size_t>(tariff_kind);
            requested_by_country[country] = saturating_add(
                requested_by_country[country], _tariff_country_requests[index],
                _saturation_count);
        }
    }
    for (int32_t kind = 0; domestic_fiscal_active &&
            kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
        for (const int32_t cell : _epoch_settlement_cells) {
            if (cell < 0 || cell >= _cell_count.get()) continue;
            const int32_t country = _epoch_cell_country[cell];
            if (country < 0 || country >= _epoch_country_count) continue;
            const size_t lane = static_cast<size_t>(cell) *
                ACTIVE_TAX_KIND_COUNT + kind;
            const bool history_matches =
                _fiscal_previous_country_handles[cell] ==
                    _epoch_country_handles[country];
            if (!history_matches)
                _fiscal_previous_requests.write_scalar(lane, 0, market_mutation_sink());
            int64_t reservation_request = history_matches
                ? std::max<int64_t>(0, _fiscal_previous_requests[lane]) : 0;
            const uint8_t kind_bit = static_cast<uint8_t>(1U << kind);
            if (kind == CountryApi::TAX_INCOME &&
                (_epoch_cell_negative_tax_mask[static_cast<size_t>(cell)] &
                 kind_bit) != 0) {
                int64_t baseline_request = 0;
                // Reserve a bounded floor for occupations that can be entered
                // during this epoch even when their cohort is currently empty.
                // Investment and employment use the same fiscal lane, so a
                // negative income rate on a newly opened owner/employee role
                // must have budget behind it before it can attract population.
                thread_local std::vector<int64_t>
                    prospective_subsidy_by_ethnicity;
                prospective_subsidy_by_ethnicity.assign(
                    _ethnicity_ids.size(), 0);
                if (country >= 0 && country + 1 < static_cast<int32_t>(
                        _epoch_country_building_type_offsets.size())) {
                    const int32_t type_begin =
                        _epoch_country_building_type_offsets[country];
                    const int32_t type_end =
                        _epoch_country_building_type_offsets[country + 1];
                    auto consider_profession = [&](int32_t profession) {
                        if (profession < 0 || profession >=
                                static_cast<int32_t>(_profession_ids.size()))
                            return;
                        const size_t profession_available_index =
                            static_cast<size_t>(country) * _profession_ids.size() +
                            static_cast<size_t>(profession);
                        if (profession_available_index >=
                                _epoch_country_profession_available.size() ||
                            _epoch_country_profession_available[
                                profession_available_index] == 0)
                            return;
                        const int32_t rate = frozen_tax_rate(
                            cell, CountryApi::TAX_INCOME, profession);
                        const int32_t mode = frozen_tax_mode(
                            cell, CountryApi::TAX_INCOME, profession);
                        if (rate >= 0) return;
                        for (int32_t ethnicity = 0; ethnicity <
                                static_cast<int32_t>(_ethnicity_ids.size());
                             ++ethnicity) {
                            const int32_t signature =
                                signature_for_profession_ethnicity(
                                    profession, ethnicity);
                            if (signature < 0) continue;
                            const int64_t days = std::max(1, _epoch_days.get());
                            const int64_t subsidy =
                                mode == CountryApi::TAX_MODE_ABSOLUTE
                                    ? saturating_mul(
                                        std::abs(static_cast<int64_t>(rate)),
                                        days, _saturation_count)
                                    : mul_div_sat(
                                        saturating_mul(
                                            living_cost_for_signature(
                                                cell, signature,
                                                _living_cost_base_plan_id,
                                                _saturation_count),
                                            days, _saturation_count),
                                        std::abs(static_cast<int64_t>(rate)),
                                        10000, _saturation_count);
                            prospective_subsidy_by_ethnicity[
                                static_cast<size_t>(ethnicity)] = std::max(
                                    prospective_subsidy_by_ethnicity[
                                        static_cast<size_t>(ethnicity)],
                                    subsidy);
                        }
                    };
                    for (int32_t cursor = type_begin; cursor < type_end;
                         ++cursor) {
                        if (cursor < 0 || cursor >= static_cast<int32_t>(
                                _epoch_country_building_type_indices.size()))
                            continue;
                        const int32_t type_id =
                            _epoch_country_building_type_indices[cursor];
                        if (type_id < 0 || type_id >= static_cast<int32_t>(
                                _building_types.size())) continue;
                        const BuildingType &type = _building_types[type_id];
                        consider_profession(type.owner_profession_id);
                        for (int32_t role = 0; role < type.employee_count;
                             ++role) {
                            consider_profession(_building_employee_roles[
                                type.employee_begin + role].profession_id);
                        }
                    }
                }
                population_store().for_each_in_cell(cell, [&](int32_t slot) {
                    const int32_t signature = static_cast<int32_t>(
                        population_store().signature_id[slot]);
                    const int32_t profession = signature >= 0 &&
                            signature < static_cast<int32_t>(_signatures.size())
                        ? _signatures[signature].profession_id : -1;
                    const int32_t rate = frozen_tax_rate(
                        cell, CountryApi::TAX_INCOME, profession);
                    const int32_t mode = frozen_tax_mode(
                        cell, CountryApi::TAX_INCOME, profession);
                    if (population_store().population[slot] <= 0) return;
                    const int64_t days = std::max(1, _epoch_days.get());
                    const int64_t population = std::max<int64_t>(
                        0, population_store().population[slot]);
                    if (mode == CountryApi::TAX_MODE_ABSOLUTE) {
                        if (rate < 0) {
                            baseline_request = saturating_add(
                                baseline_request,
                                saturating_mul(
                                    saturating_mul(
                                        std::abs(static_cast<int64_t>(rate)),
                                        population, _saturation_count),
                                    days, _saturation_count),
                                _saturation_count);
                        }
                        return;
                    }
                    const int64_t per_person_daily = living_cost_for_signature(
                        cell, signature, _living_cost_base_plan_id,
                        _saturation_count);
                    const int64_t floor_base_per_person = saturating_mul(
                        per_person_daily, days, _saturation_count);
                    const int64_t floor_base = saturating_mul(
                        floor_base_per_person, population, _saturation_count);
                    if (rate < 0) {
                        _income_subsidy_floor_by_slot[slot] = floor_base;
                        baseline_request = saturating_add(
                            baseline_request,
                            mul_div_sat(
                                floor_base,
                                std::abs(static_cast<int64_t>(rate)), 10000,
                                _saturation_count),
                            _saturation_count);
                    }
                    const int32_t ethnicity = signature >= 0 && signature <
                            static_cast<int32_t>(_signatures.size())
                        ? _signatures[signature].ethnicity_id : -1;
                    if (ethnicity >= 0 && ethnicity < static_cast<int32_t>(
                            prospective_subsidy_by_ethnicity.size())) {
                        const int64_t current_subsidy = rate < 0
                            ? mul_div_sat(
                                floor_base_per_person,
                                std::abs(static_cast<int64_t>(rate)), 10000,
                                _saturation_count)
                            : 0;
                        const int64_t incremental = std::max<int64_t>(
                            0, prospective_subsidy_by_ethnicity[
                                static_cast<size_t>(ethnicity)] -
                                current_subsidy);
                        baseline_request = saturating_add(
                            baseline_request,
                            saturating_mul(
                                incremental,
                                population, _saturation_count),
                            _saturation_count);
                    }
                });
                reservation_request = std::max(
                    reservation_request, baseline_request);
            } else if (kind == CountryApi::TAX_BUSINESS &&
                       (_epoch_cell_negative_tax_mask[static_cast<size_t>(cell)] &
                        kind_bit) != 0 &&
                       cell_due_investment_review(cell, day_index)) {
                // Without this the business lane can only ever budget what a
                // previous epoch actually requested, so a cell with no
                // subsidised producer yet quotes zero to a greenfield
                // entrant: expected_fiscal_transfer needs both a reservation
                // request and a budget before it returns anything. Seed the
                // review cells this epoch will actually evaluate, bounded by
                // one building of the single most valuable subsidised type so
                // the escrow stays proportional to what investment can start.
                const int64_t prospective =
                    prospective_business_subsidy_request(cell, country);
                if (prospective > reservation_request) {
                    ++_fiscal_business_prospective_lanes;
                    _fiscal_business_prospective_request = saturating_add(
                        _fiscal_business_prospective_request,
                        prospective - reservation_request, _saturation_count);
                    reservation_request = prospective;
                }
            }
            _fiscal_reservation_requests[lane] = reservation_request;
            requested_by_country[country] = saturating_add(
                requested_by_country[country],
                reservation_request,
                _saturation_count);
        }
    }
    _fiscal_reservation_continuation = {};
    _fiscal_reservation_continuation.country_count = _epoch_country_count;
    _fiscal_reservation_continuation.day_index = day_index;
    _fiscal_reservation_continuation.requested_by_country =
        std::move(requested_by_country);
    _fiscal_reservation_continuation.active =
        _epoch_country_count > 0;
    _fiscal_reservation_continuation.phase =
        _fiscal_reservation_continuation.active ? 1 : 2;
    return true;
}

bool NativeEconomyRuntime::advance_fiscal_reservation(std::string &error) {
    error.clear();
    FiscalReservationContinuation &continuation =
        _fiscal_reservation_continuation;
    if (!continuation.active) return true;
    const auto started = std::chrono::steady_clock::now();
    const auto fail = [&](const char *reason) {
        continuation.phase = 3;
        continuation.last_error = reason;
        continuation.active = false;
        error = reason;
        _epoch_begin_fiscal_ms += std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return false;
    };
    if (continuation.phase != 1 || continuation.country_count < 0 ||
        continuation.requested_by_country.size() !=
            static_cast<size_t>(continuation.country_count) ||
        continuation.country_cursor < 0 ||
        continuation.country_cursor > continuation.country_count) {
        return fail("fiscal_reservation_continuation_invalid");
    }
    if (continuation.country_cursor >= continuation.country_count) {
        continuation.phase = 2;
        continuation.active = false;
        _epoch_begin_fiscal_ms += std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return true;
    }

    const int32_t country = continuation.country_cursor;
    const int64_t requested = std::max<int64_t>(0,
        continuation.requested_by_country[static_cast<size_t>(country)]);
    // Government research procurement spends post-fiscal treasury cash. If
    // subsidy/tariff reservation empties the purse, queued techs starve with
    // market stock still present. Keep one epoch of the configured daily
    // research budget spendable whenever auto-purchase is on.
    int64_t research_floor = 0;
    bool research_enabled = false;
    int64_t research_daily_budget = 0;
    int64_t research_demand = 0;
    if (_country_runtime != nullptr &&
        research_procurement_policy_for(
            country, research_enabled, research_daily_budget, research_demand) &&
        research_enabled && research_daily_budget > 0) {
        research_floor = saturating_mul(
            research_daily_budget, std::max(1, _epoch_days.get()), _saturation_count);
    }
    const int64_t spendable = std::max<int64_t>(
        0, country_reads().cash_for_slot(country));
    const int64_t reservable =
        std::max<int64_t>(0, spendable - research_floor);
    // Keep the original weight total as the allocation denominator. Capping
    // it to treasury cash would allocate more subsidy than the real escrow.
    // An in-flight request also keeps its admitted amount across peer retries.
    const int64_t reserve_request = continuation.pending_request_id != 0
        ? continuation.last_requested : std::min(requested, reservable);
    continuation.last_requested = reserve_request;
    int64_t reserved = 0;
    if (reserve_request > 0) {
        std::string fiscal_transaction_error;
        if (!coordinate_country_fiscal_transaction(
                country, CountryApi::ECONOMY_ASSET_FISCAL_RESERVE,
                reserve_request, reserved, fiscal_transaction_error,
                &continuation.pending_request_id)) {
            if (fiscal_transaction_error == "country_economy_asset_host_pending")
                return true;
            return fail(fiscal_transaction_error.empty()
                ? "fiscal_reserve_transaction_failed"
                : fiscal_transaction_error.c_str());
        }
        continuation.pending_request_id = 0;
        if (reserved <= 0 || reserved > reserve_request)
            return fail("fiscal_reserve_quantity_invalid");
    }
    _fiscal_escrow_by_country.write_scalar(static_cast<size_t>(country), reserved, market_mutation_sink());
    continuation.last_reserved = reserved;

    const bool domestic_fiscal_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            (1U << CountryApi::TAX_INCOME) |
            (1U << CountryApi::TAX_CONSUMPTION) |
            (1U << CountryApi::TAX_BUSINESS))) != 0;
    int64_t prefix = 0;
    int64_t allocated = 0;
    for (int32_t kind = 0; domestic_fiscal_active &&
            kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
        for (const int32_t cell : _epoch_settlement_cells) {
            if (cell < 0 || cell >= _cell_count.get() ||
                _epoch_cell_country[cell] != country) continue;
            const size_t lane = static_cast<size_t>(cell) *
                ACTIVE_TAX_KIND_COUNT + kind;
            if (lane >= _fiscal_reservation_requests.size() ||
                lane >= _fiscal_budgets.size() ||
                lane >= _fiscal_remaining.size() ||
                lane >= _fiscal_fulfillment_q16.size())
                return fail("fiscal_reservation_lane_shape_invalid");
            prefix = saturating_add(prefix,
                std::max<int64_t>(0, _fiscal_reservation_requests[lane]),
                _saturation_count);
            const int64_t next = requested > 0
                ? mul_div_sat(reserved, prefix, requested, _saturation_count)
                : 0;
            const int64_t share = std::max<int64_t>(0, next - allocated);
            allocated = next;
            _fiscal_budgets[lane] = share;
            _fiscal_remaining[lane] = share;
            const int64_t request = std::max<int64_t>(
                0, _fiscal_reservation_requests[lane]);
            // A lane with no reservation request also got no share, so the
            // honest promise ratio is zero. The lane still bootstraps: the
            // first epoch records its request through apply_fiscal_tax and
            // the next epoch reserves treasury cash against it.
            _fiscal_fulfillment_q16[lane] = request > 0
                ? static_cast<int32_t>(std::clamp<int64_t>(mul_div_sat(
                    share, Q16_ONE, request, _saturation_count),
                    0, Q16_ONE))
                : 0;
        }
    }
    // Continue the same stable reservation order with import then export
    // tariff intents. Their budget is tracked per country because an intent
    // is country-level history while the active endpoint lane is discovered
    // later by trade dispatch.
    for (int32_t tariff_kind = 0; tariff_kind < 2; ++tariff_kind) {
        const size_t tariff_index = static_cast<size_t>(country) * 2U +
            static_cast<size_t>(tariff_kind);
        if (tariff_index >= _tariff_country_requests.size() ||
            tariff_index >= _tariff_country_budgets.size() ||
            tariff_index >= _tariff_country_remaining.size())
            return fail("fiscal_reservation_tariff_shape_invalid");
        const int64_t request = _tariff_country_requests[tariff_index];
        prefix = saturating_add(prefix, request, _saturation_count);
        const int64_t next = requested > 0
            ? mul_div_sat(reserved, prefix, requested, _saturation_count)
            : 0;
        const int64_t share = std::max<int64_t>(0, next - allocated);
        allocated = next;
        _tariff_country_budgets[tariff_index] = share;
        _tariff_country_remaining[tariff_index] = share;
    }
    ++continuation.country_cursor;
    if (continuation.country_cursor >= continuation.country_count) {
        continuation.phase = 2;
        continuation.active = false;
    }
    _epoch_begin_fiscal_ms += std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return true;
}

} // namespace pk
