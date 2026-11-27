#include "runtime_economy_army_personnel_includes.inc"

namespace pk {

// File-local Q16 one: the store is standalone and the runtime constants are
// nested, so both sides share this alias instead of repeating the literal.
constexpr int32_t kLaneQ16One = ArmyPersonnelStore::LANE_Q16_ONE;

// ─────────────────────── NativeEconomyRuntime: lane commands ──────────────────

int64_t NativeEconomyRuntime::army_lane_country_handle(int32_t cell) const {
    if (_country_runtime == nullptr) return 0;
    if (cell < 0 || cell >= _cell_count.get()) return 0;
    return country_api::country_handle_for_cell(*_country_runtime, cell);
}

bool NativeEconomyRuntime::queue_or_commit_army_lane(const StructuralCommand &record,
                                                     std::string &error,
                                                     int64_t &moved) {
    moved = 0;
    if (_epoch_active) {
        // The structural stage still runs later in this epoch, so the ordinary
        // deferred path is both correct and in-order.
        _structural_commands.push_back(record);
        moved = record.population;
        return true;
    }
    // Between epochs (the POD command drain at a committed day boundary) that
    // day's structural stage is already behind us, so queueing would only be
    // picked up by the NEXT epoch. That is a full day of latency the lane
    // contract does not allow (the D+1 batch must be visible on D+1), so run the
    // very same structural record through the very same structural path now.
    int64_t committed = 0;
    if (!commit_structural_army_lane(record, error, &committed)) return false;
    moved = committed;
    return true;
}

bool NativeEconomyRuntime::apply_army_lane_command(const Command &cmd,
                                                   std::string &error,
                                                   int64_t &settled) {
    settled = 0;
    // Same idempotency contract as COMMAND_MILITARY_CONVERT_COHORT: the POD plan
    // and the epoch drain both reach this switch, so a repeated sequence must
    // not move people twice.
    static thread_local int64_t recent_seq[64] = {};
    static thread_local size_t recent_at = 0;
    if (cmd.sequence != 0) {
        for (int64_t seen : recent_seq) {
            if (seen == cmd.sequence) return true;
        }
        recent_seq[recent_at % 64] = cmd.sequence;
        ++recent_at;
    }
    switch (cmd.opcode) {
    case COMMAND_ARMY_EMBARK: {
        const int32_t cell = cmd.i32_0;
        const int32_t signature = cmd.i32_1;
        const uint64_t army = cmd.target_handle;
        const int64_t heads = std::max<int64_t>(0, cmd.i64_0);
        if (army == 0) {
            error = "army_embark_handle_missing";
            return false;
        }
        if (cell < 0 || cell >= _cell_count.get() || signature < 0 ||
            signature >= static_cast<int32_t>(_signatures.size())) {
            error = "army_embark_target_invalid";
            return false;
        }
        if (heads <= 0) return true;
        int64_t remaining = heads;
        auto consume_signature = [&](int32_t source_signature) -> bool {
            if (remaining <= 0) return true;
            const int32_t source = population_store().find_signature(
                cell, static_cast<uint32_t>(source_signature));
            if (source < 0 || population_store().active[source] == 0) return true;
            const int64_t available = std::max<int64_t>(
                0, population_store().population[source]);
            const int64_t moved = std::min(remaining, available);
            if (moved <= 0) return true;
            // A formation may contain soldiers from more than one ethnicity.
            // Keep the source signature on each structural record so every live
            // cohort contributes before the lane reports a shortfall.
            const StructuralCommand record{STRUCTURAL_ARMY_EMBARK, source, cell,
                                           source_signature, moved,
                                           static_cast<int64_t>(army),
                                           cmd.sequence};
            int64_t committed_heads = 0;
            if (!queue_or_commit_army_lane(record, error, committed_heads)) return false;
            settled += committed_heads;
            remaining -= committed_heads;
            return true;
        };
        if (!consume_signature(signature)) return false;
        const int32_t soldier_profession = _signatures[static_cast<size_t>(signature)].profession_id;
        for (int32_t ethnicity = 0;
             remaining > 0 && ethnicity < static_cast<int32_t>(_ethnicity_ids.size());
             ++ethnicity) {
            const int32_t candidate = signature_for_profession_ethnicity(
                soldier_profession, ethnicity);
            if (candidate < 0 || candidate == signature) continue;
            if (!consume_signature(candidate)) return false;
        }
        return true;
    }
    case COMMAND_ARMY_DISEMBARK: {
        const int32_t cell = cmd.i32_0;
        int32_t signature = cmd.i32_1;
        const uint64_t army = cmd.target_handle;
        const int64_t heads = std::max<int64_t>(0, cmd.i64_0);
        if (army == 0) {
            error = "army_disembark_handle_missing";
            return false;
        }
        const int32_t row = _army_personnel.find(army);
        if (row == ArmyPersonnelStore::NO_ROW) {
            error = "army_disembark_lane_missing";
            return false;
        }
        // The bridge can send -1 when the destination cell has no existing
        // soldier cohort.  In that case the lane's own signature is the only
        // authoritative target identity; rejecting the command here would
        // strand the heads after Military has already returned the lots to the
        // destination garrison.
        if (signature < 0)
            signature = _army_personnel.signature_id[static_cast<size_t>(row)];
        if (cell < 0 || cell >= _cell_count.get() || signature < 0 ||
            signature >= static_cast<int32_t>(_signatures.size())) {
            error = "army_disembark_target_invalid";
            return false;
        }
        const int64_t available = std::max<int64_t>(
            0, _army_personnel.population[static_cast<size_t>(row)]);
        const int64_t moved = std::min(heads, available);
        if (moved <= 0) return true;
        const StructuralCommand record{STRUCTURAL_ARMY_DISEMBARK, -1, cell,
                                       signature, moved,
                                       static_cast<int64_t>(army),
                                       cmd.sequence};
        int64_t committed_heads = 0;
        if (!queue_or_commit_army_lane(record, error, committed_heads)) return false;
        settled = committed_heads;
        return true;
    }
    case COMMAND_ARMY_MERGE_LANES: {
        // Lane -> lane only: no cohort is touched, so this needs no structural
        // record. src = target_cohort, dst = payload1.
        const uint64_t src_handle = cmd.target_handle;
        const uint64_t dst_handle = static_cast<uint64_t>(cmd.i64_1);
        if (src_handle == 0 || dst_handle == 0) {
            error = "army_merge_handle_missing";
            return false;
        }
        if (src_handle == dst_handle) return true;
        const int32_t src = _army_personnel.find(src_handle);
        if (src == ArmyPersonnelStore::NO_ROW) {
            error = "army_merge_source_lane_missing";
            return false;
        }
        const int32_t dst = _army_personnel.ensure(dst_handle);
        if (dst == ArmyPersonnelStore::NO_ROW) {
            error = "army_merge_destination_allocation_failed";
            return false;
        }
        const size_t s = static_cast<size_t>(src);
        const size_t d = static_cast<size_t>(dst);
        const int64_t src_pop = std::max<int64_t>(0, _army_personnel.population[s]);
        const int64_t src_funds = _army_personnel.funds[s];
        const int64_t dst_pop = std::max<int64_t>(0, _army_personnel.population[d]);
        if (_army_personnel.population[d] == 0 &&
            _army_personnel.country_handle[d] == 0) {
            // Destination lane was just created: inherit the source identity so
            // the merged people keep a country and a consumption plan.
            _army_personnel.country_handle[d] = _army_personnel.country_handle[s];
            _army_personnel.cell[d] = _army_personnel.cell[s];
            _army_personnel.profession_id[d] = _army_personnel.profession_id[s];
            _army_personnel.plan_id[d] = _army_personnel.plan_id[s];
            _army_personnel.signature_id[d] = _army_personnel.signature_id[s];
            _army_personnel.ration_q16[d] = _army_personnel.ration_q16[s];
        }
        const int64_t merged_pop = dst_pop + src_pop;
        if (merged_pop > 0) {
            const auto blend = [&](int32_t dst_value, int32_t src_value) {
                const int64_t weighted = saturating_add(
                    mul_div_sat(dst_value, dst_pop, 1, _saturation_count),
                    mul_div_sat(src_value, src_pop, 1, _saturation_count),
                    _saturation_count);
                return static_cast<int32_t>(
                    std::clamp<int64_t>(weighted / merged_pop, 0, kLaneQ16One - 1));
            };
            _army_personnel.satisfaction_q16[d] = blend(
                _army_personnel.satisfaction_q16[d],
                _army_personnel.satisfaction_q16[s]);
            _army_personnel.survival_q16[d] = blend(
                _army_personnel.survival_q16[d], _army_personnel.survival_q16[s]);
        }
        _army_personnel.population[d] = merged_pop;
        _army_personnel.funds[d] = saturating_add(
            _army_personnel.funds[d], src_funds, _saturation_count);
        _army_personnel.epoch_income[d] = saturating_add(
            _army_personnel.epoch_income[d], _army_personnel.epoch_income[s],
            _saturation_count);
        _army_personnel.epoch_expense[d] = saturating_add(
            _army_personnel.epoch_expense[d], _army_personnel.epoch_expense[s],
            _saturation_count);
        // Family / notable-person sub-ledgers travel with the people. v1 never
        // populates them, but the merge must not silently drop them.
        const int32_t fam_begin = _army_personnel.family_offset[s];
        const int32_t fam_count = _army_personnel.family_len[s];
        if (fam_count > 0) {
            _army_personnel.family_offset[d] =
                static_cast<int32_t>(_army_personnel.family_handles.size());
            for (int32_t k = 0; k < fam_count; ++k) {
                const size_t at = static_cast<size_t>(fam_begin + k);
                if (at >= _army_personnel.family_handles.size()) break;
                _army_personnel.family_handles.push_back(_army_personnel.family_handles[at]);
                _army_personnel.family_people.push_back(_army_personnel.family_people[at]);
                _army_personnel.family_funds.push_back(_army_personnel.family_funds[at]);
                ++_army_personnel.family_len[d];
            }
        }
        const int32_t per_begin = _army_personnel.person_offset[s];
        const int32_t per_count = _army_personnel.person_len[s];
        if (per_count > 0) {
            _army_personnel.person_offset[d] =
                static_cast<int32_t>(_army_personnel.person_handles.size());
            for (int32_t k = 0; k < per_count; ++k) {
                const size_t at = static_cast<size_t>(per_begin + k);
                if (at >= _army_personnel.person_handles.size()) break;
                _army_personnel.person_handles.push_back(_army_personnel.person_handles[at]);
                ++_army_personnel.person_len[d];
            }
        }
        _army_personnel.family_len[s] = 0;
        _army_personnel.person_len[s] = 0;
        _army_personnel.population[s] = 0;
        _army_personnel.funds[s] = 0;
        _army_personnel.epoch_income[s] = 0;
        _army_personnel.epoch_expense[s] = 0;
        _army_personnel.release(src);
        settled = src_pop;
        return true;
    }
    case COMMAND_ARMY_SPLIT_LANES: {
        // Lane -> lane (army-personnel contract 2 §1.1), the partial version of
        // the merge above: `heads` people (payload0) and their proportional cash
        // leave the source lane and join the destination lane, which is created
        // on demand (country/cell copied from the source). Like 32 no cohort is
        // touched, so this needs no structural record; and like 32 it is already
        // covered by the sequence dedupe at the top of this function.
        //
        // Conservation is exact: the source is only ever debited by what the
        // destination was credited with, so population and funds summed over
        // both lanes are unchanged to the last unit (rounding stays on the
        // source, never burned).
        const uint64_t src_handle = cmd.target_handle;
        // Handles are `gen << 32 | slot` with gen >= 1, so a non-positive
        // payload1 can never name an army: refuse it instead of allocating a
        // lane under a cast-to-uint64 garbage key.
        const int64_t dst_raw = cmd.i64_1;
        const uint64_t dst_handle = static_cast<uint64_t>(dst_raw);
        if (src_handle == 0) {
            error = "army_split_source_handle_missing";
            return false;
        }
        if (dst_raw <= 0) {
            error = "army_split_destination_handle_missing";
            return false;
        }
        if (src_handle == dst_handle) return true;
        const int32_t src = _army_personnel.find(src_handle);
        if (src == ArmyPersonnelStore::NO_ROW) {
            error = "army_split_source_lane_missing";
            return false;
        }
        const size_t s = static_cast<size_t>(src);
        const int64_t src_pop = std::max<int64_t>(0, _army_personnel.population[s]);
        const int64_t heads = cmd.i64_0;
        const int64_t moved = heads <= 0 ? src_pop : std::min(heads, src_pop);
        if (heads > 0 && moved <= 0) return true;   // lane not filled yet
        // payload0 <= 0 asks for the whole lane: transfer semantics.
        const bool whole_lane = heads <= 0 || moved >= src_pop;

        const bool dst_known =
            _army_personnel.find(dst_handle) != ArmyPersonnelStore::NO_ROW;
        const int32_t dst = _army_personnel.ensure(dst_handle);
        if (dst == ArmyPersonnelStore::NO_ROW) {
            error = "army_split_destination_allocation_failed";
            return false;
        }
        const size_t d = static_cast<size_t>(dst);
        const int64_t dst_pop = std::max<int64_t>(0, _army_personnel.population[d]);
        if (!dst_known ||
            (dst_pop == 0 && _army_personnel.country_handle[d] == 0)) {
            // Fresh destination: it has no identity of its own, so it takes the
            // source's country and cell (contract) plus the consumption identity
            // the guest-consumption stage needs. A lane that merely lost its
            // people to a disembark keeps its own cell on purpose.
            _army_personnel.country_handle[d] = _army_personnel.country_handle[s];
            _army_personnel.cell[d] = _army_personnel.cell[s];
            _army_personnel.profession_id[d] = _army_personnel.profession_id[s];
            _army_personnel.plan_id[d] = _army_personnel.plan_id[s];
            _army_personnel.signature_id[d] = _army_personnel.signature_id[s];
            _army_personnel.ration_q16[d] = _army_personnel.ration_q16[s];
        }
        // Money follows people, floor division, remainder stays on the source.
        // `whole_lane` never divides by a zero population (a drained lane moves
        // whatever cash it still holds, which is 32's behaviour).
        const int64_t src_funds = _army_personnel.funds[s];
        const int64_t moved_funds = whole_lane
            ? src_funds
            : mul_div_sat(src_funds, moved, src_pop, _saturation_count);
        const int64_t src_income = _army_personnel.epoch_income[s];
        const int64_t moved_income = whole_lane
            ? src_income
            : mul_div_sat(src_income, moved, src_pop, _saturation_count);
        const int64_t src_expense = _army_personnel.epoch_expense[s];
        const int64_t moved_expense = whole_lane
            ? src_expense
            : mul_div_sat(src_expense, moved, src_pop, _saturation_count);
        const int64_t merged_pop = dst_pop + moved;
        if (merged_pop > 0) {
            // Population-weighted blend, identical to the merge (32): the
            // destination's own people keep their satisfaction, the newcomers
            // bring the source's.
            const auto blend = [&](int32_t dst_value, int32_t src_value) {
                const int64_t weighted = saturating_add(
                    mul_div_sat(dst_value, dst_pop, 1, _saturation_count),
                    mul_div_sat(src_value, moved, 1, _saturation_count),
                    _saturation_count);
                return static_cast<int32_t>(
                    std::clamp<int64_t>(weighted / merged_pop, 0, kLaneQ16One - 1));
            };
            _army_personnel.satisfaction_q16[d] = blend(
                _army_personnel.satisfaction_q16[d],
                _army_personnel.satisfaction_q16[s]);
            _army_personnel.survival_q16[d] = blend(
                _army_personnel.survival_q16[d], _army_personnel.survival_q16[s]);
        }
        _army_personnel.population[d] = saturating_add(
            _army_personnel.population[d], moved, _saturation_count);
        _army_personnel.funds[d] = saturating_add(
            _army_personnel.funds[d], moved_funds, _saturation_count);
        _army_personnel.epoch_income[d] = saturating_add(
            _army_personnel.epoch_income[d], moved_income, _saturation_count);
        _army_personnel.epoch_expense[d] = saturating_add(
            _army_personnel.epoch_expense[d], moved_expense, _saturation_count);
        // The debit is exact subtraction of what was credited, never a second
        // rounding: that is what makes the two-lane sum invariant.
        _army_personnel.population[s] = src_pop - moved;
        _army_personnel.funds[s] = src_funds - moved_funds;
        _army_personnel.epoch_income[s] = src_income - moved_income;
        _army_personnel.epoch_expense[s] = src_expense - moved_expense;
        // Family / notable-person sub-ledgers (contract §3: stored and merged,
        // never produced in v1). A whole-lane move carries the segment across
        // unless the destination already owns one (never overwrite); a partial
        // split leaves it on the source, which still holds the remaining people
        // and therefore their sub-accounts.
        const bool src_has_subledger =
            _army_personnel.family_len[s] > 0 || _army_personnel.person_len[s] > 0;
        bool subledger_handed_over = false;
        if (whole_lane && src_has_subledger &&
            _army_personnel.family_len[d] == 0 &&
            _army_personnel.person_len[d] == 0) {
            const int32_t fam_begin = _army_personnel.family_offset[s];
            const int32_t fam_count = _army_personnel.family_len[s];
            _army_personnel.family_offset[d] =
                static_cast<int32_t>(_army_personnel.family_handles.size());
            for (int32_t k = 0; k < fam_count; ++k) {
                const size_t at = static_cast<size_t>(fam_begin + k);
                if (at >= _army_personnel.family_handles.size()) break;
                _army_personnel.family_handles.push_back(
                    _army_personnel.family_handles[at]);
                _army_personnel.family_people.push_back(
                    _army_personnel.family_people[at]);
                _army_personnel.family_funds.push_back(
                    _army_personnel.family_funds[at]);
                ++_army_personnel.family_len[d];
            }
            const int32_t per_begin = _army_personnel.person_offset[s];
            const int32_t per_count = _army_personnel.person_len[s];
            _army_personnel.person_offset[d] =
                static_cast<int32_t>(_army_personnel.person_handles.size());
            for (int32_t k = 0; k < per_count; ++k) {
                const size_t at = static_cast<size_t>(per_begin + k);
                if (at >= _army_personnel.person_handles.size()) break;
                _army_personnel.person_handles.push_back(
                    _army_personnel.person_handles[at]);
                ++_army_personnel.person_len[d];
            }
            _army_personnel.family_len[s] = 0;
            _army_personnel.person_len[s] = 0;
            subledger_handed_over = true;
        }
        if (_army_personnel.population[s] <= 0 && _army_personnel.funds[s] == 0 &&
            (!src_has_subledger || subledger_handed_over)) {
            // Fully drained source (e.g. the whole lane moved): release the row
            // exactly like a disembark that empties its lane. A source that
            // still owns a sub-ledger keeps its row so nothing is dropped.
            _army_personnel.population[s] = 0;
            _army_personnel.funds[s] = 0;
            _army_personnel.epoch_income[s] = 0;
            _army_personnel.epoch_expense[s] = 0;
            _army_personnel.release(src);
        }
        settled = moved;
        return true;
    }
    case COMMAND_ARMY_LANE_PAY: {
        // Army pay (army-pay contract §1): the wages of the people who actually
        // march with the formation, paid into the lane instead of the garrison
        // cell they left behind. Three rules shape this:
        //  1. Never mint. The cash comes from the existing conserved
        //     treasury debit (one committed fiscal reserve), so the treasury loses
        //     exactly what the lane gains; there is no second issuance path.
        //  2. The command names the lane by ARMY HANDLE (target_cohort), the
        //     same key 30-33 use; `settled` reports the amount actually moved so
        //     the receipt fold can compare it with the requested amount.
        //  3. Already covered by the `sequence` dedupe at the top of this
        //     function: the POD plan and the epoch drain both reach this switch,
        //     and paying twice would double the payroll.
        const uint64_t army = cmd.target_handle;
        const int64_t country = cmd.i64_1;
        const int64_t requested = std::max<int64_t>(0, cmd.i64_0);
        if (army == 0) {
            error = "army_lane_pay_handle_missing";
            return false;
        }
        if (country == 0) {
            error = "army_lane_pay_country_missing";
            return false;
        }
        const int32_t row = _army_personnel.find(army);
        if (row == ArmyPersonnelStore::NO_ROW) {
            // No lane: the formation never mustered people here (or was already
            // disbanded). A stable no-op with settled 0 — the receipt reports a
            // failed payment rather than an economy fatal.
            error = "army_lane_pay_lane_missing";
            return false;
        }
        if (requested <= 0) return true;
        // Pay through the conserved "treasury -> non-tax expenditure" path
        // (army-pay contract §1.1): the treasury loses exactly what the lane
        // gains, and nothing is minted. Use the active executor's Country
        // authority even before the main-thread suppression flag is mirrored:
        //
        //  * SYNC Country (single-threaded, no worker domination):
        //    Commit one fiscal reserve, then credit the lane in this call.
        //    FISCAL_COLLECT credits Country; it is not a payment confirmation.
        //    The legacy deferred-upkeep helper has a separate, unchanged contract.
        //  * WORKER Country (whole-graph ACTIVE): that synchronous escrow refuses
        //    with `country_worker_unique_writer`. The cohort-cash coordinator solves
        //    exactly this problem for cohorts, and it does so SYNCHRONOUSLY on the
        //    worker thread (prepare -> service peer -> finish), which is why it
        //    keeps the epoch's audit intact. The lane is credited by the peer's
        //    side effect, keyed by the formation handle, so the money is conserved
        //    inside one window.
        //
        // Never route through `block_or_enqueue_country_worker_asset`: that
        // enqueues work the peer settles on its own cadence, splitting the debit
        // and the credit across audit windows (observed as
        // `money_conservation_failed`).
        int64_t moved = 0;
        std::string cash_error;
        if (_country_runtime != nullptr && country_api::economy_available(*_country_runtime) &&
            _simulation_host != nullptr && _simulation_host->on_worker_thread() &&
            _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) &&
            (_d7_operation_gate_mask &
             (1u << static_cast<uint32_t>(
                 CountryApi::ECONOMY_ASSET_TREASURY_SPEND))) != 0u) {
            if (!pay_army_lane_from_worker_country(army, country, requested, moved,
                                                   cash_error)) {
                error = cash_error.empty() ? "army_lane_pay_worker_route_failed"
                                           : cash_error;
                return false;
            }
        } else {
            if (_country_runtime == nullptr || !country_api::economy_available(*_country_runtime)) {
                error = "army_lane_pay_country_unavailable";
                return false;
            }
            // Complete the same debit protocol as the old reserve half. Do not
            // credit Country back before paying the lane: that would mint cash.
            const auto debit = [&]() -> int64_t {
                const auto port = country_api::fiscal_return_port(*_country_runtime);
                const auto begun = port.submit_cash(port.reserve_intent(
                    country, requested, -1, -1));
                if (!static_cast<bool>(begun.get("ok", false))) return 0;
                const uint64_t id = static_cast<int64_t>(begun.get("transaction_id", 0));
                const uint64_t session = static_cast<int64_t>(begun.get("session_epoch", 0));
                const uint64_t generation = static_cast<int64_t>(begun.get("country_generation", 0));
                if (id == 0 || session == 0 || generation == 0) return 0;
                const auto prepared = port.prepared({id, session, generation, id}, true, "");
                if (!static_cast<bool>(prepared.get("ok", false))) return 0;
                const auto committed = port.apply(id);
                if (!static_cast<bool>(committed.get("ok", false))) return 0;
                const auto applied = port.applied({id, session, generation, id}, true, "");
                return static_cast<bool>(applied.get("ok", false)) &&
                        godot::String(applied.get("status_name", "")) == "completed"
                    ? static_cast<int64_t>(applied.get("committed_quantity", 0)) : 0;
            };
            moved = debit();
            if (moved <= 0) {
                // The treasury could not fund any of it (or Country is unavailable).
                // Nothing was booked, so the lane must not grow by a single unit.
                error = "army_lane_pay_treasury_empty";
                return false;
            }
            const size_t r = static_cast<size_t>(row);
            _army_personnel.funds[r] = saturating_add(
                _army_personnel.funds[r], moved, _saturation_count);
            _army_personnel.epoch_income[r] = saturating_add(
                _army_personnel.epoch_income[r], moved, _saturation_count);
            trace_record_cashflow(_army_personnel.cell[r], army, CASHFLOW_TRANSFER,
                                  0, moved);
        }
        settled = moved;
        return moved > 0;
    }
    default:
        error = "army_lane_command_unsupported";
        return false;
    }
}

// ───────────────────────── NativeEconomyRuntime: queries ─────────────────────

int64_t NativeEconomyRuntime::military_army_population(uint64_t army_handle) const {
    const int32_t row = _army_personnel.find(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return 0;
    return std::max<int64_t>(0, _army_personnel.population[static_cast<size_t>(row)]);
}

int64_t NativeEconomyRuntime::military_army_funds(uint64_t army_handle) const {
    const int32_t row = _army_personnel.find(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return 0;
    return _army_personnel.funds[static_cast<size_t>(row)];
}

int32_t NativeEconomyRuntime::military_army_cell(uint64_t army_handle) const {
    const int32_t row = _army_personnel.find(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return -1;
    return _army_personnel.cell[static_cast<size_t>(row)];
}

int32_t NativeEconomyRuntime::military_army_satisfaction_q16(uint64_t army_handle) const {
    const int32_t row = _army_personnel.find(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return kLaneQ16One - 1;
    return _army_personnel.satisfaction_q16[static_cast<size_t>(row)];
}

int64_t NativeEconomyRuntime::military_army_lane_population() const {
    return _army_personnel.total_population();
}

bool NativeEconomyRuntime::military_army_lane_split_supported() const {
    // Opcode 33 (COMMAND_ARMY_SPLIT_LANES) is built unconditionally, so this is
    // a constant. The Military bridge needs the probe anyway: it is compiled
    // against an Economy that may predate the opcode, and `army.split` /
    // `army.transfer` must keep the old "the lane stays put" translation (and
    // say so in the report) instead of emitting a command admission will drop.
    return true;
}

bool NativeEconomyRuntime::military_army_lane_pay_supported() const {
    // Opcode 34 (COMMAND_ARMY_LANE_PAY) is built unconditionally, so the opcode is
    // always available (same contract as the split-lane probe: the Military bridge
    // must translate MILITARY_INTENT_ARMY_PAY into a no-op plus a failed receipt
    // rather than an opcode admission would reject).
    //
    // Paying needs a treasury debit that lands in the same epoch as the lane credit.
    // Two shapes provide that: the synchronous fiscal escrow when Country still
    // accepts sync store writes, and the synchronous worker peer cycle when Country
    // is worker-authoritative. Both need the Country runtime to be usable.
    return _country_runtime != nullptr && country_api::economy_available(*_country_runtime);
}

void NativeEconomyRuntime::set_military_army_ration(uint64_t army_handle,
                                                    int32_t ration_q16) {
    const int32_t row = _army_personnel.ensure(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return;
    _army_personnel.ration_q16[static_cast<size_t>(row)] =
        static_cast<int32_t>(std::clamp<int32_t>(ration_q16, 0, kLaneQ16One));
}

void NativeEconomyRuntime::set_military_army_ration(uint64_t army_handle,
                                                    int32_t ration_q16,
                                                    int32_t cell) {
    const int32_t row = _army_personnel.ensure(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return;
    const size_t r = static_cast<size_t>(row);
    _army_personnel.ration_q16[r] =
        static_cast<int32_t>(std::clamp<int32_t>(ration_q16, 0, kLaneQ16One));
    if (cell < 0 || cell >= _cell_count.get()) return;
    if (_army_personnel.cell[r] != cell) {
        _army_personnel.cell[r] = cell;
        if (_army_personnel.population[r] > 0)
            _army_personnel.country_handle[r] = static_cast<uint64_t>(
                army_lane_country_handle(cell));
    }
}

void NativeEconomyRuntime::sum_army_personnel_holdings(int64_t &population,
                                                       int64_t &funds,
                                                       int64_t &saturation_count) const {
    population = saturating_add(population, _army_personnel.total_population(),
                                saturation_count);
    funds = saturating_add(funds, _army_personnel.total_funds(),
                           saturation_count);
}

} // namespace pk
