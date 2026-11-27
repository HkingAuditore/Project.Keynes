#include "economy_runtime_building_employment_includes.inc"

namespace pk {

namespace {
}

bool NativeEconomyRuntime::reconcile_building_employment_after_population_change(
        const std::vector<int32_t> &affected_cells, std::string &error) {
    thread_local std::vector<int32_t> stable_cells;
    thread_local std::vector<uint32_t> stable_cell_stamp;
    thread_local uint32_t stable_cell_generation = 0;
    if (stable_cell_stamp.size() < static_cast<size_t>(_cell_count.get()))
        stable_cell_stamp.resize(static_cast<size_t>(_cell_count.get()), 0);
    ++stable_cell_generation;
    if (stable_cell_generation == 0) {
        std::fill(stable_cell_stamp.begin(), stable_cell_stamp.end(), 0);
        stable_cell_generation = 1;
    }
    stable_cells.clear();
    for (const int32_t cell : affected_cells) {
        if (cell < 0 || cell >= _cell_count.get() ||
            stable_cell_stamp[cell] == stable_cell_generation) continue;
        stable_cell_stamp[cell] = stable_cell_generation;
        stable_cells.push_back(cell);
    }
    std::sort(stable_cells.begin(), stable_cells.end());

    return reconcile_building_employment_cells_range(
        stable_cells, 0, static_cast<int32_t>(stable_cells.size()), error);
}

bool NativeEconomyRuntime::reconcile_building_employment_cells_range(
        const std::vector<int32_t> &stable_cells, int32_t begin, int32_t end,
        std::string &error) {
    const int32_t professions = static_cast<int32_t>(_profession_ids.size());
    thread_local std::vector<int32_t> priority;
    thread_local std::vector<int64_t> sig_population;
    thread_local std::vector<int64_t> sig_owner_filled;
    thread_local std::vector<int64_t> sig_owner_distributed;
    thread_local std::vector<int64_t> mobile_population_by_profession;
    thread_local std::vector<int64_t> profession_capacity;
    thread_local std::vector<int64_t> profession_filled;
    thread_local std::vector<int64_t> profession_prefix;
    thread_local std::vector<int64_t> profession_distributed;
    thread_local std::vector<int64_t> owner_filled_by_profession;
    thread_local std::vector<int64_t> owner_population_by_profession;
    thread_local std::vector<int64_t> owner_prefix_by_profession;
    thread_local std::vector<int64_t> owner_distributed_by_profession;
    thread_local std::vector<uint32_t> signature_stamp;
    thread_local std::vector<uint32_t> profession_stamp;
    thread_local std::vector<int32_t> idle_source_slots;
    thread_local std::vector<int32_t> idle_destination_signatures;
    thread_local std::vector<int64_t> idle_populations;
    thread_local uint32_t scratch_generation = 0;
    // 鏈牸瀹為檯鍑虹幇杩囩殑 signature銆傛憡娲惧惊鐜潬瀹冨彇浠ｅ鏁村紶 _signatures 琛ㄧ殑鎵弿銆?
    thread_local std::vector<int32_t> touched_signatures;

    begin = std::clamp(begin, 0, static_cast<int32_t>(stable_cells.size()));
    end = std::clamp(end, begin, static_cast<int32_t>(stable_cells.size()));

    if (sig_population.size() < _signatures.size()) {
        sig_population.resize(_signatures.size(), 0);
        sig_owner_filled.resize(_signatures.size(), 0);
        sig_owner_distributed.resize(_signatures.size(), 0);
        signature_stamp.resize(_signatures.size(), 0);
    }
    if (profession_capacity.size() < static_cast<size_t>(professions)) {
        profession_capacity.resize(professions, 0);
        profession_filled.resize(professions, 0);
        profession_prefix.resize(professions, 0);
        profession_distributed.resize(professions, 0);
        profession_stamp.resize(professions, 0);
    }
    mobile_population_by_profession.assign(static_cast<size_t>(professions), 0);
    owner_filled_by_profession.assign(static_cast<size_t>(professions), 0);
    owner_population_by_profession.assign(static_cast<size_t>(professions), 0);
    owner_prefix_by_profession.assign(static_cast<size_t>(professions), 0);
    owner_distributed_by_profession.assign(static_cast<size_t>(professions), 0);

    for (int32_t ordinal = begin; ordinal < end; ++ordinal) {
        const int32_t cell = stable_cells[ordinal];
        ++scratch_generation;
        if (scratch_generation == 0) {
            std::fill(signature_stamp.begin(), signature_stamp.end(), 0);
            std::fill(profession_stamp.begin(), profession_stamp.end(), 0);
            scratch_generation = 1;
        }
        std::fill(mobile_population_by_profession.begin(),
                  mobile_population_by_profession.end(), 0);
        std::fill(owner_filled_by_profession.begin(),
                  owner_filled_by_profession.end(), 0);
        std::fill(owner_population_by_profession.begin(),
                  owner_population_by_profession.end(), 0);
        std::fill(owner_prefix_by_profession.begin(),
                  owner_prefix_by_profession.end(), 0);
        std::fill(owner_distributed_by_profession.begin(),
                  owner_distributed_by_profession.end(), 0);
        touched_signatures.clear();
        idle_source_slots.clear();
        idle_destination_signatures.clear();
        idle_populations.clear();
        auto touch_signature = [&](int32_t signature) {
            if (signature_stamp[signature] == scratch_generation) return;
            signature_stamp[signature] = scratch_generation;
            touched_signatures.push_back(signature);
            sig_population[signature] = 0;
            sig_owner_filled[signature] = 0;
            sig_owner_distributed[signature] = 0;
        };
        auto touch_profession = [&](int32_t profession) {
            if (profession_stamp[profession] == scratch_generation) return;
            profession_stamp[profession] = scratch_generation;
            profession_capacity[profession] = 0;
            profession_filled[profession] = 0;
            profession_prefix[profession] = 0;
            profession_distributed[profession] = 0;
        };
        const int32_t first = _building_cell_offsets[cell];
        const int32_t last = _building_cell_offsets[cell + 1];
        int64_t mobile_population_total = 0;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const uint32_t sig = population_store().signature_id[slot];
            if (sig < sig_population.size()) {
                touch_signature(static_cast<int32_t>(sig));
                sig_population[sig] = saturating_add(sig_population[sig],
                    std::max<int64_t>(0, population_store().population[slot]), _saturation_count);
                if (!is_merchant_slot(slot) && sig < _signatures.size()) {
                    const int32_t profession = _signatures[sig].profession_id;
                    if (profession >= 0 && profession < professions) {
                        const int64_t pop = std::max<int64_t>(0, population_store().population[slot]);
                        const int64_t attached = saturating_add(
                            std::max<int64_t>(0, population_store().owner_employed[slot]),
                            std::max<int64_t>(0, population_store().employee_employed[slot]),
                            _saturation_count);
                        mobile_population_by_profession[profession] = saturating_add(
                            mobile_population_by_profession[profession],
                            std::max<int64_t>(0, pop - attached), _saturation_count);
                        mobile_population_total = saturating_add(
                            mobile_population_total,
                            std::max<int64_t>(0, pop - attached), _saturation_count);
                    }
                }
            }
        });

        priority.clear();
        thread_local std::vector<int64_t> priority_income;
        thread_local std::vector<uint8_t> priority_survival;
        priority_income.assign(static_cast<size_t>(last - first), 0);
        priority_survival.assign(static_cast<size_t>(last - first), 0);
        for (int32_t g = first; g < last; ++g) {
            {
                // Groups that will be skipped must still be zeroed, but when
                // they are already empty the mutable column borrow is pure
                // waste; check the read-only view first.
                const auto view = building_view(static_cast<size_t>(g));
                if (view.cell != cell || view.count <= 0 ||
                    !building_available(cell, view.type_id, true)) {
                    bool already_zero = view.filled_owner == 0;
                    if (already_zero && view.type_id >= 0 &&
                        view.type_id < static_cast<int32_t>(
                            _building_types.size())) {
                        const BuildingType &type = _building_types[view.type_id];
                        for (int32_t r = 0; r < type.employee_count; ++r) {
                            const int32_t role_index =
                                view.employee_fill_begin + r;
                            if (role_index >= 0 &&
                                role_index < static_cast<int32_t>(
                                    _building_employee_filled.size()) &&
                                _building_employee_filled[role_index] != 0) {
                                already_zero = false;
                                break;
                            }
                        }
                    }
                    if (!already_zero) {
                        auto group = building_at(static_cast<size_t>(g));
                        group.filled_owner = 0;
                        if (group.type_id >= 0 && group.type_id <
                                static_cast<int32_t>(_building_types.size())) {
                            const BuildingType &type =
                                _building_types[group.type_id];
                            for (int32_t r = 0; r < type.employee_count; ++r)
                                _building_employee_filled.write_scalar(
                                    group.employee_fill_begin + r, 0,
                                    market_mutation_sink());
                        }
                    }
                    continue;
                }
            }
            auto group = building_at(static_cast<size_t>(g));
            int64_t priority_sat = 0;
            const BuildingType &type = _building_types[group.type_id];
            const int32_t owner_profession = group.owner_signature_id >= 0 &&
                    group.owner_signature_id < static_cast<int32_t>(_signatures.size())
                ? _signatures[group.owner_signature_id].profession_id : -1;
            // A mobile unemployed cohort can enter a different profession;
            // do not use its current (usually unemployed) profession as a
            // hard fillability gate for the target role.
            // Vacancy is an outcome, not a reason to lower the building's
            // counterfactual income signal. Current staffing remains an
            // execution constraint in production, but never suppresses demand.
            const int64_t owner_fillability = Q16_ONE;
            int64_t employee_fillability = Q16_ONE;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int64_t slots = saturating_mul(group.count,
                    role.slots_per_building, priority_sat);
                const int32_t fill_index = group.employee_fill_begin + r;
                const int64_t filled = fill_index >= 0 && fill_index <
                        static_cast<int32_t>(_building_employee_filled.size())
                    ? std::max<int64_t>(0, _building_employee_filled[fill_index]) : 0;
                const int64_t available = mobile_population_total;
                employee_fillability = std::min(employee_fillability,
                    slots > 0 ? std::clamp<int64_t>(mul_div_sat(
                        saturating_add(filled, available, priority_sat), Q16_ONE,
                        slots, priority_sat), 0, Q16_ONE) : Q16_ONE);
            }
            EconomyCostProbe::record("owner_quote.call.emp_priority",
                                      _current_day.get(), 0.0, 1);
            const OwnerOpportunityQuote quote = owner_opportunity_quote(
                group, owner_fillability, employee_fillability, priority_sat);
            priority_income[static_cast<size_t>(g - first)] =
                quote.disposable_survival_power_per_day;
            priority_survival[static_cast<size_t>(g - first)] =
                quote.survival_priority ? 1 : 0;
            if (quote.survival_priority) ++_building_survival_priority_candidates;
            ++_building_owner_opportunity_quotes;
            if (!quote.feasible) ++_building_owner_opportunity_zero_feasible;
            _saturation_count = saturating_add(
                _saturation_count, priority_sat, _saturation_count);
            priority.push_back(g);
        }
        std::stable_sort(priority.begin(), priority.end(), [&](int32_t a, int32_t b) {
            const uint8_t survival_a = priority_survival[static_cast<size_t>(a - first)];
            const uint8_t survival_b = priority_survival[static_cast<size_t>(b - first)];
            if (survival_a != survival_b) return survival_a > survival_b;
            const int64_t income_a = priority_income[static_cast<size_t>(a - first)];
            const int64_t income_b = priority_income[static_cast<size_t>(b - first)];
            if (income_a != income_b) return income_a > income_b;
            return a < b;
        });

        // Clamp owner fills by profession rather than canonical signature. The
        // latter would silently evict owners whose ethnicity differs from the
        // building profile during this reconciliation pass.
        //
        // 涓嬮潰涓夊鎽婃淳寰幆鍘熸潵鍚勬壂涓€閬嶆暣寮?_signatures 琛紙闅忓瓨妗ｅ崟璋冨闀夸笖姘镐笉
        // 鏀剁缉锛夛紝鍙负鎸戝嚭鏈牸瀹為檯鍑虹幇鐨勯偅鍑犱釜 signature銆傛敼鎴愰亶鍘?touched 鍒楄〃锛?
        // 鎺掑簭涓€娆″嵆鍙繚鎸佸悓涓€涓?signature id 鍗囧簭锛屽墠缂€鍜屾憡娲鹃€愪綅涓嶅彉銆?
        std::sort(touched_signatures.begin(), touched_signatures.end());
        for (const int32_t sig : touched_signatures) {
            if (sig_population[sig] <= 0) continue;
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) continue;
            owner_population_by_profession[profession] = saturating_add(
                owner_population_by_profession[profession], sig_population[sig],
                _saturation_count);
        }
        for (int32_t g : priority) {
            auto group = building_at(static_cast<size_t>(g));
            const int32_t sig = group.owner_signature_id;
            if (sig < 0 || sig >= static_cast<int32_t>(sig_population.size())) {
                error = "building_owner_signature_invalid_after_population_change";
                return false;
            }
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) {
                group.filled_owner = 0;
                continue;
            }
            int64_t &remaining = owner_population_by_profession[profession];
            group.filled_owner = std::min(
                std::max<int64_t>(0, group.filled_owner), remaining);
            remaining -= group.filled_owner;
            owner_filled_by_profession[profession] = saturating_add(
                owner_filled_by_profession[profession], group.filled_owner,
                _saturation_count);
        }

        // Distribute each profession's owner jobs over the live local
        // profession|ethnicity cohorts in stable signature order.
        for (const int32_t sig : touched_signatures) sig_owner_filled[sig] = 0;
        std::fill(owner_population_by_profession.begin(),
                  owner_population_by_profession.end(), 0);
        for (const int32_t sig : touched_signatures) {
            if (sig_population[sig] <= 0) continue;
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) continue;
            owner_population_by_profession[profession] = saturating_add(
                owner_population_by_profession[profession], sig_population[sig],
                _saturation_count);
        }
        std::fill(owner_prefix_by_profession.begin(), owner_prefix_by_profession.end(), 0);
        std::fill(owner_distributed_by_profession.begin(),
                  owner_distributed_by_profession.end(), 0);
        for (const int32_t sig : touched_signatures) {
            if (sig_population[sig] <= 0) continue;
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) continue;
            owner_prefix_by_profession[profession] = saturating_add(
                owner_prefix_by_profession[profession], sig_population[sig],
                _saturation_count);
            const int64_t next = owner_population_by_profession[profession] > 0
                ? mul_div_sat(owner_filled_by_profession[profession],
                    owner_prefix_by_profession[profession],
                    owner_population_by_profession[profession], _saturation_count)
                : 0;
            sig_owner_filled[sig] = std::max<int64_t>(0,
                next - owner_distributed_by_profession[profession]);
            owner_distributed_by_profession[profession] = next;
        }

        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) return;
            const int32_t sig = static_cast<int32_t>(population_store().signature_id[slot]);
            const int32_t profession = _signatures[sig].profession_id;
            if (profession == _unemployed_profession_id) return;
            touch_profession(profession);
            const int64_t owner = std::min(sig_owner_filled[sig],
                std::max<int64_t>(0, population_store().population[slot]));
            profession_capacity[profession] = saturating_add(
                profession_capacity[profession],
                std::max<int64_t>(0, population_store().population[slot] - owner),
                _saturation_count);
        });
        for (int32_t g : priority) {
            auto group = building_view(static_cast<size_t>(g));
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                touch_profession(role.profession_id);
                const int32_t index = group.employee_fill_begin + r;
                const int64_t available = std::max<int64_t>(
                    0, profession_capacity[role.profession_id] -
                        profession_filled[role.profession_id]);
                _building_employee_filled.write_scalar(index, std::min(
                    std::max<int64_t>(0, _building_employee_filled[index]), available), market_mutation_sink());
                profession_filled[role.profession_id] = saturating_add(
                    profession_filled[role.profession_id],
                    _building_employee_filled[index], _saturation_count);
            }
        }

        int64_t owner_after = 0;
        int64_t employee_after = 0;
        int64_t unemployed_after = 0;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t sig = static_cast<int32_t>(population_store().signature_id[slot]);
            const int32_t profession = _signatures[sig].profession_id;
            const int64_t population = std::max<int64_t>(0, population_store().population[slot]);
            const int64_t owner = std::min(population, std::max<int64_t>(
                0, sig_owner_filled[sig] - sig_owner_distributed[sig]));
            sig_owner_distributed[sig] = saturating_add(
                sig_owner_distributed[sig], owner, _saturation_count);
            int64_t employee = 0;
            if (!is_merchant_slot(slot) && profession != _unemployed_profession_id) {
                const int64_t capacity = std::max<int64_t>(0, population - owner);
                profession_prefix[profession] = saturating_add(
                    profession_prefix[profession], capacity, _saturation_count);
                const int64_t next = profession_capacity[profession] > 0
                    ? mul_div_sat(profession_filled[profession],
                        profession_prefix[profession], profession_capacity[profession],
                        _saturation_count) : 0;
                employee = std::min(capacity, std::max<int64_t>(
                    0, next - profession_distributed[profession]));
                profession_distributed[profession] = next;
            }
            population_store().owner_employed.write_scalar(slot, owner, market_mutation_sink());
            population_store().employee_employed.write_scalar(slot, employee, market_mutation_sink());
            owner_after = saturating_add(owner_after, owner, _saturation_count);
            employee_after = saturating_add(employee_after, employee, _saturation_count);
            unemployed_after = saturating_add(unemployed_after,
                std::max<int64_t>(0, population - owner - employee), _saturation_count);
            if (!is_merchant_slot(slot) && profession != _unemployed_profession_id) {
                const int64_t idle = std::max<int64_t>(0,
                    population - owner - employee);
                // Military v1: soldiers never reflux into the unemployed pool.
                if (idle > 0 && !profession_is_state_service_only(profession)) {
                    const int32_t ethnicity = _signatures[sig].ethnicity_id;
                    const int32_t unemployed_signature =
                        unemployed_signature_for_ethnicity(ethnicity);
                    if (unemployed_signature >= 0 &&
                        unemployed_signature != sig) {
                        idle_source_slots.push_back(slot);
                        idle_destination_signatures.push_back(unemployed_signature);
                        idle_populations.push_back(idle);
                    }
                }
            }
        });
        // Reconciliation can release the last building for a profession. The
        // employment counters above are already zero, but the cohort identity
        // must also move into unemployed|ethnicity so the next hiring pass sees
        // the population in the mobile pool. Defer the moves until after the
        // cell scan because move_cohort_population may release source slots.
        for (size_t i = 0; i < idle_source_slots.size(); ++i) {
            bool drained = false;
            if (!move_cohort_population(idle_source_slots[i], cell,
                    idle_destination_signatures[i], idle_populations[i], error,
                    &drained)) {
                return false;
            }
        }
        replace_employment_metrics_for_cell(
            cell, owner_after, employee_after, unemployed_after);
    }
    return true;
}

} // namespace pk
