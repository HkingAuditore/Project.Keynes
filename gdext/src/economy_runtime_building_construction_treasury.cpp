#include "economy_runtime_building_construction_includes.inc"

namespace pk {

using namespace godot;

int32_t NativeEconomyRuntime::treasury_build_owner_signature(
        int32_t cell, int32_t type_id) const {
    if (cell < 0 || cell >= _cell_count.get() || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size())) return -1;
    const BuildingType &requested_type = _building_types[type_id];
    // State lots are owned by the reserved state owner signature, never by a
    // live cohort: their owner profession is state_service_only, which no
    // plan-driven cohort occupies, so the "dominant ethnicity" fallback below
    // would report -1 in every cell that has no soldier cohort yet - i.e. the
    // first barracks of a country could never be built. This is the same
    // signature the state payroll group and the military reader use, so the
    // lot lands where the rest of the state lane already looks for it.
    if (requested_type.kind == 3 && _state_owner_signature >= 0)
        return _state_owner_signature;
    const int32_t owner_profession = requested_type.owner_profession_id;
    if (_building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
        for (int32_t group = _building_cell_offsets[cell];
             group < _building_cell_offsets[cell + 1]; ++group) {
            const auto candidate = building_view(static_cast<size_t>(group));
            if (candidate.type_id == type_id && candidate.count > 0 &&
                candidate.owner_signature_id >= 0 &&
                candidate.owner_signature_id < static_cast<int32_t>(_signatures.size()) &&
                _signatures[candidate.owner_signature_id].profession_id == owner_profession) {
                return candidate.owner_signature_id;
            }
        }
    }
    std::vector<int64_t> population_by_ethnicity(_ethnicity_ids.size(), 0);
    int64_t local_sat = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t signature = static_cast<int32_t>(population_store().signature_id[slot]);
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size())) return;
        const int32_t ethnicity = _signatures[signature].ethnicity_id;
        if (ethnicity < 0 || ethnicity >= static_cast<int32_t>(
                population_by_ethnicity.size())) return;
        population_by_ethnicity[ethnicity] = saturating_add(
            population_by_ethnicity[ethnicity],
            std::max<int64_t>(0, population_store().population[slot]), local_sat);
    });
    int32_t dominant_ethnicity = -1;
    int64_t dominant_population = -1;
    for (int32_t ethnicity = 0; ethnicity < static_cast<int32_t>(
            population_by_ethnicity.size()); ++ethnicity) {
        const int32_t signature = signature_for_profession_ethnicity(
            owner_profession, ethnicity);
        if (signature < 0) continue;
        if (population_by_ethnicity[ethnicity] > dominant_population) {
            dominant_population = population_by_ethnicity[ethnicity];
            dominant_ethnicity = ethnicity;
        }
    }
    return dominant_ethnicity >= 0
        ? signature_for_profession_ethnicity(owner_profession, dominant_ethnicity)
        : -1;
}

bool NativeEconomyRuntime::apply_treasury_sponsored_build_command(
        const Command &cmd, std::string &error) {
    const int32_t cell = cmd.i32_0;
    const int32_t type_id = cmd.i32_1;
    auto reject = [&](const char *code, const char *step = "economy") {
        _last_building_rejection_reason = code;
        ++_rejected_commands;
        stage_construction_receipt(cmd, false, code, 0, 0, 0, step);
        return true;
    };
    if (!cmd.treasury_construction_policy_valid())
        return reject("unsupported_ownership_policy");
    if (_country_runtime == nullptr ||
        !country_reads().valid_handle(static_cast<int64_t>(cmd.target_handle)) ||
        cell < 0 || cell >= _cell_count.get() || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || cmd.i64_0 != 1)
        return reject("construction_target_invalid");
    if (country_reads().country_handle_for_cell(cell) !=
            static_cast<int64_t>(cmd.target_handle))
        return reject("construction_cell_not_owned");
    const int32_t country_slot = cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    if (country_slot < 0 || country_slot >= static_cast<int32_t>(
            _epoch_country_political_regime_capabilities.size()) ||
        (_epoch_country_political_regime_capabilities[static_cast<size_t>(country_slot)] &
         CountryApi::CAP_TREASURY_CONSTRUCTION) == 0)
        return reject("political_regime_lacks_treasury_construction");
    if (!building_available(cell, type_id, true))
        return reject("construction_technology_locked");
    if (!building_constructible(cell, type_id, true))
        return reject("construction_obsolete");
    if (!evaluate_building_conditions(type_id, cell))
        return reject("construction_conditions_failed");
    if (!family_free_building_resources_legal(cell, type_id, 1))
        return reject("construction_resource_unavailable");

    int32_t military_building = -1;
    int32_t military_slot = -1;
    if (cmd.military_construction()) {
        if (_simulation_host == nullptr)
            return reject("military_executor_unavailable", "military");
        if (const char *reason = _simulation_host->preflight_military_construction(
                cmd.target_handle, cell, type_id, false, _current_day.get(),
                military_building, military_slot))
            return reject(reason, "military");
    }

    const int32_t owner_signature = treasury_build_owner_signature(cell, type_id);
    if (owner_signature < 0) return reject("construction_owner_signature_unavailable");
    const int32_t market = market_store().cell_to_market[cell];
    if (market < 0 || market >= market_store().market_count.get())
        return reject("construction_market_unavailable");
    const int32_t cost_factor = country_slot >= 0 && country_slot <
            static_cast<int32_t>(_epoch_country_construction_cost_factor_q16.size())
        ? _epoch_country_construction_cost_factor_q16[country_slot] : Q16_ONE;
    std::vector<int64_t> country_stock(_good_ids.size(), 0);
    for (size_t good = 0; good < country_stock.size(); ++good) {
        country_stock[good] = std::max<int64_t>(0,
            country_reads().good_for_handle(
                static_cast<int64_t>(cmd.target_handle),
                static_cast<int32_t>(good)));
    }
    ConstructionMaterialPlan material_plan;
    if (!plan_construction_materials(cell, type_id, 1, cost_factor,
                                     material_plan, &country_stock))
        return reject("construction_materials_insufficient");
    const std::vector<int32_t> &good_ids = material_plan.good_ids;
    const std::vector<int64_t> &required = material_plan.quantities;
    const BuildingType &type = _building_types[type_id];

    std::vector<int64_t> treasury_used(good_ids.size(), 0);
    std::vector<int64_t> market_used(good_ids.size(), 0);
    int64_t total_cash = 0;
    GoodsBill treasury_bill;
    int64_t treasury_goods_total = 0;
    int64_t market_goods_total = 0;
    for (size_t i = 0; i < good_ids.size(); ++i) {
        treasury_used[i] = std::min<int64_t>(required[i], std::max<int64_t>(0,
            country_reads().good_for_handle(
                static_cast<int64_t>(cmd.target_handle), good_ids[i])));
        market_used[i] = required[i] - treasury_used[i];
        const int64_t lane = market_store().index(market, good_ids[i]);
        if (market_store().stock[lane] < market_used[i])
            return reject("construction_materials_insufficient");
        total_cash = saturating_add(total_cash, treasury_bill.add(market_used[i], market_store().price[lane], _saturation_count), _saturation_count);
        treasury_goods_total = saturating_add(
            treasury_goods_total, treasury_used[i], _saturation_count);
        market_goods_total = saturating_add(
            market_goods_total, market_used[i], _saturation_count);
    }
    if (total_cash > 0 && (_merchant_offsets.size() !=
            static_cast<size_t>(_cell_count.get() + 1) ||
            _merchant_offsets[cell] >= _merchant_offsets[cell + 1]))
        return reject("construction_market_unavailable");
    if (country_reads().cash_for_handle(
            static_cast<int64_t>(cmd.target_handle)) < total_cash)
        return reject("construction_treasury_cash_insufficient");
    int64_t committed_cash = 0;
    if (!coordinate_country_treasury_spend(
            cell, market, static_cast<int64_t>(cmd.target_handle), good_ids,
            treasury_used, market_used, total_cash, committed_cash, error)) {
        if (error == "country_economy_asset_cash_insufficient")
            return reject("construction_treasury_cash_insufficient");
        return reject(error.empty() ? "construction_treasury_preflight_drift"
                                    : error.c_str());
    }
    // 国库按市价为缺料付款：现金付给本地商人，工程本身不提现，所以这笔钱只会
    // 从国库消失而没有税种凭证。记进非税支出，避免「支出」漏账。
    note_non_tax_outflow(static_cast<uint64_t>(cmd.target_handle),
        NON_TAX_CONSTRUCTION, committed_cash);

    for (size_t i = 0; i < good_ids.size(); ++i) {
        const int64_t lane = market_store().index(market, good_ids[i]);
        _construction_goods_consumed = saturating_add(
            _construction_goods_consumed, required[i], _saturation_count);
        const int32_t signal = ensure_market_signal_index(cell, good_ids[i]);
        if (signal >= 0 && signal < static_cast<int32_t>(
                _epoch_nonhousehold_withdrawals.size())) {
            _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                _epoch_nonhousehold_withdrawals[signal], required[i],
                _saturation_count);
        }
    }
    const int32_t time_factor = country_slot >= 0 && country_slot <
            static_cast<int32_t>(_epoch_country_construction_time_factor_q16.size())
        ? _epoch_country_construction_time_factor_q16[country_slot] : Q16_ONE;
    const int32_t construction_days = type.construction_days <= 0 ? 0 :
        std::max<int32_t>(1, static_cast<int32_t>(mul_div_sat(
            type.construction_days, time_factor, Q16_ONE, _saturation_count)));
    append_pending_construction({cell, type_id, owner_signature, 1,
        _sample_day + construction_days, cmd.sequence, 0, 0, 0, 0});
    trace_append(EVENT_CONSTRUCTION_STARTED, static_cast<int32_t>(_stage),
        cell, SUBJECT_BUILDING_GROUP, owner_signature, type_id,
        OWNERSHIP_TREASURY_SPONSORED_PRIVATE, 1, total_cash,
        _sample_day + construction_days, cmd.sequence, nullptr);
    if (cmd.military_construction())
        _simulation_host->commit_military_construction(
            cell, military_building, military_slot, _current_day.get(), _sample_day + construction_days);
    stage_construction_receipt(cmd, true, "ok", total_cash,
                               treasury_goods_total, market_goods_total);
    return true;
}

// Formal treasury-sponsored build ingress.
//
// `submit_commands` is fail-closed whenever the StageOps production writer is
// effective (`economy_legacy_ingress_disabled`), which is the shipping
// configuration, so a player build request could never reach the epoch queue
// through the legacy batch. This boundary queues the very same Command the
// legacy path queued: the apply step, the receipt, and the country asset
// bridge stay untouched.
//
// The command is always applied inside an epoch (`_pending_commands` /
// worker inbox), because `apply_treasury_sponsored_build_command` reads the
// epoch-frozen `_epoch_cell_country` and the country cost/time factors.
godot::Dictionary NativeEconomyRuntime::queue_treasury_sponsored_build(
        int64_t country_handle, int32_t cell_idx, int32_t type_id,
        int64_t effective_day, int64_t sequence, bool queue_for_worker, bool military_order) {
    godot::Dictionary out;
    out["effective_day"] = effective_day;
    out["sequence"] = sequence;
    auto reject = [&](const char *code) {
        out["ok"] = false;
        out["admitted"] = false;
        out.erase("effective_day");
        out["code"] = godot::String(code);
        out["message"] = godot::String(code);
        return out;
    };
    if (effective_day < 0 || sequence < 0) return reject("construction_target_invalid");
    if (!queue_for_worker) {
        if (!_bootstrapped) return reject("economy_not_bootstrapped");
        if (_fatal) return reject("economy_fatal");
        if (_save.active || _restore.active) return reject("save_restore_active");
        if (effective_day < 0 || sequence < 0 || cell_idx < 0 ||
            cell_idx >= _cell_count.get() || type_id < 0 ||
            type_id >= static_cast<int32_t>(_building_types.size()))
            return reject("construction_target_invalid");
        if (_country_runtime == nullptr ||
            !country_reads().valid_handle(country_handle))
            return reject("construction_target_invalid");
    }
    Command command;
    command.opcode = COMMAND_TREASURY_SPONSORED_BUILD;
    command.effective_day = effective_day;
    command.sequence = sequence;
    command.target_handle = static_cast<uint64_t>(country_handle);
    command.i32_0 = cell_idx;
    command.i32_1 = type_id;
    command.i64_0 = 1;
    command.i64_1 = military_order ? OWNERSHIP_TREASURY_MILITARY_ORDER
                                   : OWNERSHIP_TREASURY_SPONSORED_PRIVATE;
    // The caller is the main thread and may race the worker mid-day, so the
    // worker-owned case goes through the mutex-guarded inbox drained at epoch
    // begin on the owning thread.
    if (queue_for_worker) {
        enqueue_worker_command(command);
    } else {
        command.submit_order = _next_submit_order++;
        _pending_commands.push_back(command);
    }
    out["ok"] = true;
    out["admitted"] = true;
    out["code"] = "construction_queued";
    out["message"] = "construction_queued";
    out["queued"] = true;
    out["cell_idx"] = cell_idx;
    out["type_id"] = type_id;
    return out;
}

// Remove the state-owned lot in Economy. The military stage reads the
// resulting building count and updates its derived cache on this day.
bool NativeEconomyRuntime::apply_treasury_sponsored_demolish_command(
        const Command &cmd, std::string &error) {
    const int32_t cell = cmd.i32_0;
    const int32_t type_id = cmd.i32_1;
    auto reject = [&](const char *code, const char *step = "economy") {
        _last_building_rejection_reason = code;
        ++_rejected_commands;
        stage_construction_receipt(cmd, false, code, 0, 0, 0, step);
        return true;
    };
    if (!cmd.treasury_construction_policy_valid())
        return reject("unsupported_ownership_policy");
    if (cell < 0 || cell >= _cell_count.get() || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) ||
        cmd.i64_0 <= 0)
        return reject("demolish_target_invalid");
    if (_country_runtime == nullptr ||
        !country_reads().valid_handle(static_cast<int64_t>(cmd.target_handle)))
        return reject("demolish_target_invalid");
    // Only state lots go through this ingress; an industrial group must use the
    // ordinary owner-driven COMMAND_DEMOLISH (11) so its cohort keeps paying.
    if (_building_types[type_id].kind != 3) return reject("demolish_not_state_owned");
    int32_t military_building = -1;
    int32_t military_slot = -1;
    if (cmd.military_construction()) {
        if (country_reads().country_handle_for_cell(cell) !=
                static_cast<int64_t>(cmd.target_handle))
            return reject("construction_cell_not_owned");
        if (_simulation_host == nullptr)
            return reject("military_executor_unavailable", "military");
        if (const char *reason = _simulation_host->preflight_military_construction(
                cmd.target_handle, cell, type_id, true, _current_day.get(),
                military_building, military_slot))
            return reject(reason, "military");
    }
    // Ownership and signature are both derived from the catalog, not from the
    // caller: a state group's owner is the reserved state signature, which is
    // the only key under which the build ingress could have created it.
    const int32_t owner_signature = treasury_build_owner_signature(cell, type_id);
    if (owner_signature < 0) return reject("demolish_state_owner_unresolved");
    const int32_t group_id = find_building_group(cell, type_id, owner_signature);
    if (group_id < 0) return reject("demolish_state_building_absent");
    const int64_t before = buildings_store().group_units[group_id];
    if (before < cmd.i64_0) return reject("demolish_owned_count_insufficient");
    record_annual_event(cell, AnnualMetric::REMOVED, cmd.i64_0);
    buildings_store().group_units.write_scalar(group_id, before - cmd.i64_0);
    _building_handle_index_clean = false;
    std::vector<EventLeg> event_legs;
    if (trace_detail_for_cell(cell)) {
        event_legs.push_back({FIELD_BUILDING_COUNT, SUBJECT_BUILDING_GROUP,
                              owner_signature, type_id, before,
                              buildings_store().group_units[group_id]});
    }
    // Same event and stage as the ordinary demolish so a replay sees one shape:
    // the removal is a ledger-apply fact regardless of who ordered it.
    trace_append(EVENT_BUILDING_DEMOLISHED, static_cast<int32_t>(Stage::LEDGER_APPLY),
                 cell, SUBJECT_BUILDING_GROUP, owner_signature, type_id, -1,
                 cmd.i64_0, before, buildings_store().group_units[group_id],
                 cmd.sequence, event_legs.empty() ? nullptr : &event_legs);
    _structural_touched_cells.push_back(cell);
    if (cmd.military_construction())
        _simulation_host->commit_military_construction(
            cell, military_building, military_slot, _current_day.get(), -1);
    stage_construction_receipt(cmd, true, "ok");
    return true;
}

godot::Dictionary NativeEconomyRuntime::queue_treasury_sponsored_demolish(
        int64_t country_handle, int32_t cell_idx, int32_t type_id,
        int64_t count, int64_t effective_day, int64_t sequence,
        bool queue_for_worker, bool military_order) {
    godot::Dictionary out;
    out["effective_day"] = effective_day;
    out["sequence"] = sequence;
    auto reject = [&](const char *code) {
        out["ok"] = false;
        out["admitted"] = false;
        out.erase("effective_day");
        out["code"] = godot::String(code);
        out["message"] = godot::String(code);
        return out;
    };
    if (effective_day < 0 || sequence < 0) return reject("demolish_target_invalid");
    if (!queue_for_worker) {
        if (!_bootstrapped) return reject("economy_not_bootstrapped");
        if (_fatal) return reject("economy_fatal");
        if (_save.active || _restore.active) return reject("save_restore_active");
        if (effective_day < 0 || sequence < 0 || count <= 0 || cell_idx < 0 ||
            cell_idx >= _cell_count.get() || type_id < 0 ||
            type_id >= static_cast<int32_t>(_building_types.size()))
            return reject("demolish_target_invalid");
        if (_country_runtime == nullptr ||
            !country_reads().valid_handle(country_handle))
            return reject("demolish_target_invalid");
        if (_building_types[type_id].kind != 3) return reject("demolish_not_state_owned");
    }
    Command command;
    command.opcode = COMMAND_TREASURY_SPONSORED_DEMOLISH;
    command.effective_day = effective_day;
    command.sequence = sequence;
    command.target_handle = static_cast<uint64_t>(country_handle);
    command.i32_0 = cell_idx;
    command.i32_1 = type_id;
    command.i64_0 = count;
    command.i64_1 = military_order ? OWNERSHIP_TREASURY_MILITARY_ORDER
                                   : OWNERSHIP_TREASURY_SPONSORED_PRIVATE;
    if (queue_for_worker) {
        enqueue_worker_command(command);
    } else {
        command.submit_order = _next_submit_order++;
        _pending_commands.push_back(command);
    }
    out["ok"] = true;
    out["admitted"] = true;
    out["code"] = "demolish_queued";
    out["message"] = "demolish_queued";
    out["queued"] = true;
    out["cell_idx"] = cell_idx;
    out["type_id"] = type_id;
    out["count"] = count;
    return out;
}

} // namespace pk
