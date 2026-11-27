#include "economy_runtime_building_employment_includes.inc"

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

bool NativeEconomyRuntime::run_building_employment_cell(
        int32_t cell, bool allow_owner_job_reallocation, std::string &error) {
    // This scope mutates cohorts and role fills, which are explicit quote keys;
    // market prices, stock, environment and frozen modifiers stay unchanged.
    LivingCostMemoScope memo(*this, true);
    const auto employment_cell_started = Clock::now();
    Clock::time_point employment_hire_started{};
    Clock::time_point employment_mobility_started{};
    Clock::time_point employment_ownerjob_started{};
    int64_t employment_candidate_scans = 0;
    int64_t employment_pool_lookups = 0;
    if (!prepare_cell_wages(cell, error)) return false;
    EconomyCostProbe::record("employment.cell_prepare", _current_day.get(),
                             elapsed_ms(employment_cell_started));
    const auto employment_targets_started = Clock::now();
    // demand[p] = profession p 鏈懆鏈?employee 鐩爣涔嬪拰锛沠ill[p] = 澶圭揣鍚庡湪宀?
    // employee 涔嬪拰銆備簩鑰呭湪 A1 涓ゆ閫昏緫涓 std::fill 閲嶇疆澶嶇敤锛堣涓嬶級銆?
    thread_local std::vector<int64_t> demand;
    thread_local std::vector<int64_t> fill;
    auto employment_utilization_q16 = [&](BuildingGroupConstRef group) {
        const int32_t index = static_cast<int32_t>(group.index);
        int64_t utilization = index >= 0 && index < static_cast<int32_t>(
                _building_planned_capacity_before_climate_q16.size())
            ? _building_planned_capacity_before_climate_q16[index]
            : group.planned_utilization_q16;
        return std::clamp<int64_t>(utilization, 0, Q16_ONE);
    };
    auto employee_living_cost = [&](int32_t role_index) -> int64_t {
        if (role_index < 0 || role_index >= static_cast<int32_t>(
                _building_role_living_cost.size())) return 0;
        return std::max(_building_role_base_living_cost[role_index],
                        _building_role_living_cost[role_index]);
    };
    auto expected_employee_gross = [&](const JobRole &role,
                                       int32_t role_index) -> int64_t {
        const int32_t signal = labor_signal_index(cell, role.profession_id);
        const int64_t living_floor = signal >= 0
            ? std::max(_labor_signals.base_living_cost[signal],
                _labor_signals.role_living_cost[signal]) : 0;
        const int64_t market_quote = signal >= 0 && signal <
                static_cast<int32_t>(_labor_signals.contract_wage_ema.size())
            ? std::max(_labor_signals.contract_wage_ema[signal],
                _labor_signals.paid_wage_ema[signal]) : 0;
        const int64_t contract = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_contract_wage.size())
            ? std::max<int64_t>(0, _building_role_contract_wage[role_index])
            : std::max(living_floor, market_quote);
        if (contract <= 0) return 0;
        const int64_t profession_paid = signal >= 0 && signal <
                static_cast<int32_t>(_labor_signals.paid_wage_ema.size())
            ? std::max<int64_t>(0, _labor_signals.paid_wage_ema[signal]) : 0;
        const int64_t due = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_base_wage_due.size())
            ? std::max<int64_t>(0, _building_role_base_wage_due[role_index]) : 0;
        const int64_t paid = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_base_wage_paid.size())
            ? std::max<int64_t>(0, _building_role_base_wage_paid[role_index]) : 0;
        const int64_t forecast_ratio_q16 = role_index >= 0 && role_index <
                static_cast<int32_t>(
                    _building_role_forecast_pay_ratio_q16.size())
            ? std::clamp<int64_t>(
                _building_role_forecast_pay_ratio_q16[role_index],
                0, Q16_ONE)
            : Q16_ONE;
        const int64_t forecast_expected = mul_div_sat(
            contract, forecast_ratio_q16, Q16_ONE, _saturation_count);
        // A new or currently empty role has no role-specific observation. Use
        // its funded absorption forecast directly; do not assume the contract
        // is collectible and do not inherit another employer's arrears.
        if (due <= 0) return forecast_expected;
        const int64_t fulfillment_q16 = due > 0
            ? std::clamp<int64_t>(mul_div_sat(
                paid, Q16_ONE, due, _saturation_count), 0, Q16_ONE)
            : Q16_ONE;
        const int64_t role_expected = mul_div_sat(
            contract, fulfillment_q16, Q16_ONE, _saturation_count);
        const int64_t blended = profession_paid > 0
            ? saturating_add(role_expected, std::min(contract, profession_paid),
                _saturation_count) / 2
            : role_expected;
        return std::clamp<int64_t>(
            std::min(blended, forecast_expected), 0, contract);
    };
    auto expected_employee_hiring_gross = [&](const JobRole &role,
                                              int32_t role_index) -> int64_t {
        const int64_t expected = expected_employee_gross(role, role_index);
        const int64_t due = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_base_wage_due.size())
            ? std::max<int64_t>(
                0, _building_role_base_wage_due[role_index])
            : 0;
        if (due > 0) return expected;
        const int32_t signal = labor_signal_index(cell, role.profession_id);
        const int64_t living_floor = signal >= 0
            ? std::max(_labor_signals.base_living_cost[signal],
                _labor_signals.role_living_cost[signal]) : 0;
        const int64_t market_quote = signal >= 0 && signal <
                static_cast<int32_t>(_labor_signals.contract_wage_ema.size())
            ? std::max(_labor_signals.contract_wage_ema[signal],
                _labor_signals.paid_wage_ema[signal]) : 0;
        const int64_t contract = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_contract_wage.size())
            ? std::max<int64_t>(
                0, _building_role_contract_wage[role_index])
            : std::max(living_floor, market_quote);
        // A cold-start vacancy has no realized payroll ratio yet. Use the
        // nominal contract for the unemployed entry path; affordability is
        // still enforced by the owner/production working-capital and input
        // gates after the person is admitted. Using contract/8 puts a
        // break-even role below its own livelihood floor and strands the
        // initial unemployed pool.
        return std::max<int64_t>(expected, contract);
    };
    const int32_t professions = static_cast<int32_t>(_profession_ids.size());
    demand.assign(professions, 0);
    fill.assign(professions, 0);
    const int32_t first = _building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)
        ? _building_cell_offsets[cell] : 0;
    const int32_t last = _building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)
        ? _building_cell_offsets[cell + 1] : 0;
    int64_t stay_q16 = Q16_ONE;
    const int64_t daily_mobility_q16 = std::clamp<int64_t>(
        _employment_mobility_daily_q16.get(), 0, Q16_ONE);
    // Track B (user-approved): job mobility lanes are cadence-limited. Skip days
    // run no mobility at all; refresh days apply the accumulated multi-day
    // probability, keeping the long-run transition rate close to exact mode.
    static const bool track_b_enabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B);
        return !(value && std::strcmp(value, "0") == 0);
    }();
    static const int32_t track_b_mobility_cadence = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_MOBILITY_CADENCE);
        const int32_t parsed = value ? std::atoi(value) : 0;
        return parsed > 0 ? std::min<int32_t>(parsed, 30) : 5;
    }();
    static const int32_t track_b_mobility_spread = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_MOBILITY_SPREAD);
        const int32_t parsed = value ? std::atoi(value) : 0;
        return parsed > 0 ? std::min<int32_t>(parsed, 32) : 1;
    }();
    int64_t mobility_days = std::max(1, _epoch_days.get());
    if (track_b_enabled && track_b_mobility_spread > 1) {
        const int32_t mobility_phase = static_cast<int32_t>(
            ((_current_day.get() % track_b_mobility_spread) +
             track_b_mobility_spread) % track_b_mobility_spread);
        if (cell >= 0 && (cell % track_b_mobility_spread) == mobility_phase) {
            mobility_days *= track_b_mobility_spread;
        } else {
            mobility_days = 0;
            EconomyCostProbe::record("employment.track_b_mobility_skip",
                                     _current_day.get(), 0.0, 1u);
        }
    } else if (track_b_enabled && track_b_mobility_cadence > 1) {
        if ((_current_day.get() % track_b_mobility_cadence) != 0) {
            mobility_days = 0;
            EconomyCostProbe::record("employment.track_b_mobility_skip",
                                     _current_day.get(), 0.0, 1u);
        } else {
            mobility_days *= track_b_mobility_cadence;
        }
    }
    for (int32_t d = 0; d < mobility_days; ++d) {
        stay_q16 = mul_div_sat(stay_q16,
            Q16_ONE - daily_mobility_q16, Q16_ONE, _saturation_count);
    }
    const int64_t mobility_period_q16 = std::clamp<int64_t>(
        Q16_ONE - stay_q16, 0, Q16_ONE);
    auto planned_role_demand = [&](BuildingGroupConstRef group,
                                   const JobRole &role, int32_t role_index) {
        // Soldiers enter only through Military ENLIST/LEVY, which Military
        // books on its roster. A state-service seat filled here would create
        // soldiers Military never sees, so it posts no hiring or mobility target.
        if (profession_is_state_service_only(role.profession_id)) return int64_t{0};
        const int64_t full = saturating_mul(group.count, role.slots_per_building,
                                            _saturation_count);
        const int64_t utilization = employment_utilization_q16(group);
        int64_t scaled = mul_div_sat(full, utilization, Q16_ONE,
                                     _saturation_count);
        if (scaled == 0 && full > 0 && utilization > 0) scaled = 1;
        return scaled;
    };
    const bool trace_detail = trace_detail_for_cell(cell);
    // A1 杩佺Щ浼?allocate/release slot锛岃８ slot id 浼氬け鏁堬紱trace 蹇収鏀瑰瓨绋冲畾
    // handle锛屼簨浠剁敓鎴愭椂鐢?valid_handle 瑙ｆ瀽鍥炲綋鍓?slot锛堝け鏁堝垯璺宠繃璇?leg锛夈€?
    thread_local std::vector<uint64_t> trace_handles;
    thread_local std::vector<int64_t> trace_owner_before;
    thread_local std::vector<int64_t> trace_employee_before;
    trace_handles.clear(); trace_owner_before.clear(); trace_employee_before.clear();
    if (trace_detail) {
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            trace_handles.push_back(population_store().handle_for_slot(slot));
            trace_owner_before.push_back(population_store().owner_employed[slot]);
            trace_employee_before.push_back(population_store().employee_employed[slot]);
        });
    }
    // ================================================================
    // A1 璺緞锛氬け涓氭睜澧為噺灏变笟锛堢粺涓€鍑€澧為噺杩佺Щ锛岀敤鎴?2026-07-16 鎷嶆澘锛?
    // ----------------------------------------------------------------
    // 涓嶅彉閲忥紙employment 缁撴潫鏃跺姣忎釜闈?merchant銆侀潪 unemployed 鐨?
    //   profession|eth slot 鎴愮珛锛夛細owner_employed + employee_employed
    //   == population锛屽嵆鍦ㄥ矖 slot 閲屾病鏈夐棽缃汉鍙ｏ紱浠讳綍鏈浠讳綍寤虹瓚闆囦剑
    //   鐨勪汉閮界湡瀹炶縼寰€ unemployed|eth slot锛堢嫭绔?cohort 韬唤 + plan_unemployed锛?
    //   娑堣垂閫€鍖栦负 survival food 鈫?satisfaction 鎺?鈫?starvation 鑷劧姝讳笂鍗囷紝
    //   澶变笟鎯╃綒鐢?demography 鑷姩鏂藉姞锛屾棤闇€纭紪姝讳骸鐜囷級銆?
    //
    // 涓ゆ缁撴瀯锛堟暟瀛︿笂绛変环浜?娑堝け娓呯悊 + 寤虹瓚椹卞姩瑁佸憳 + 鏈夐檺娴佸姩鎷涗汉"涓夐樁娈?
    //   鍚堝苟锛屼絾 owner/employee 鍦ㄥ悓涓€ slot 鍐呰嚜鐒剁珵浜?population锛屾棤闇€鍦ㄩ樁娈?
    //   闂存樉寮忎紶閫?slot 鍓╀綑瀹归噺锛夛細
    //   [绗?姝?鏋愬嚭] 姣忎釜鍦ㄥ矖 slot 鎸夋湰鍛ㄦ湡 planned_utilization 鐩爣绠?
    //     desired_working锛泂urplus = population - desired_working 鐨勯儴鍒嗚縼寰€
    //     unemployed|eth銆傛秷澶?涓嶅彲鐢ㄥ缓绛戠洰鏍囦负 0锛屽叾鍦ㄥ矖浜哄彛鑷劧鍏ㄩ儴杩涙睜銆?
    //     鎵ц鍚庢墍鏈夋椿璺?group 鐨?filled_* 琚す鍒?鐩爣鎴栨洿灏?锛屽浣欎汉鍙ｅ叏鍦ㄦ睜涓€?
    //   [绗?姝?鎷涗汉] unemployed 姹犳鍒绘眹闆嗕簡鍚?eth 鐨勫叏閮ㄥけ涓氳€咃紙鍚湰鍛ㄦ湡鍒?
    //     杩涙睜鐨?+ 鍘嗗彶闀挎湡澶变笟鐨勶級銆傛椿璺?group 鎸変紭鍏堢骇
    //     (realized_profit_margin_q16 desc, planned_utilization_q16 desc,
    //      group_index asc) 璺ㄥ缓绛戠被鍨嬫帓搴忥紝渚濇鎶?filled_owner/filled_employee
    //     琛ュ埌鐩爣锛屼粠 unemployed|eth 鐪熷疄杩佸洖瀵瑰簲 profession|eth slot锛堝彈姹?
    //     鍙敤閲忕害鏉燂級銆傛墍鏈夊彲琛屽€欓€夋寜 pay ratio 鍜?utilization 鍔犳潈姣斾緥
    //     浠庢湁闄?mobility budget 杩佸洖锛屼笉鍐嶇敱鍗曚竴鏈€楂樻敹鍏?group 鍚歌蛋鏁翠釜
    //     澶变笟姹狅紝涔熶笉鍥犲€欓€夋埅鏂€岄タ姝讳綆鎺掑悕寤虹瓚銆?
    //     鎷涗汉璺?profession锛氬け涓?farmer 鍙鎷涗负 miner锛坧rofession 鏄彲鍙樺氨涓?
    //     鐘舵€侊紝鏋舵瀯鍐崇瓥4锛夈€?
    //
    // 鍏抽敭宸ョ▼绾︽潫锛歮ove_cohort_population 浼?allocate/release slot锛岀牬鍧?
    //   for_each_in_cell 鐨勯〉閾捐凯浠ｅ櫒銆傛晠鎵€鏈夎縼绉婚兘"鍏堝彧璇婚亶鍘嗘敹闆嗚鍒掑埌
    //   thread_local 缂撳啿锛岄亶鍘嗙粨鏉熷悗鍐嶇粺涓€鎵ц杩佺Щ"锛堝 ensure_merchant_invariant锛夈€?
    //   Route B: 鍟嗘爤(merchant_post) owner 鐜板湪鍙備笌灏变笟鍒嗛厤鈥斺€攎erchant slot 鐨?
    //   owner_employed 璁″叆 filled_owner銆佺撼鍏ユ瀽鍑?鑱氬悎锛涗絾淇濆簳姣忔湁浜?cell 鑷冲皯
    //   1 涓?merchant 涓嶈瑁?鎶や綇 rebuild_merchant_ranges 鍋氬競绱㈠紩涓嶅彉閲?銆?
    //   emp_capacity 绗竴閬嶄粛璺宠繃 merchant(鍟嗕汉涓嶅仛 employee锛屼粎 owner 宀?銆?
    // ================================================================
    // The same authoritative release/hire path also owns cells whose last
    // building was removed. Empty ranges must release every non-merchant
    // profession cohort into unemployed instead of leaving an idle profession.
    {
#include "economy_runtime_building_employment_income_quotes.inc"
#include "economy_runtime_building_employment_staffing_targets.inc"
#include "economy_runtime_building_employment_release_surplus.inc"
#include "economy_runtime_building_employment_vacancy_candidates.inc"
#include "economy_runtime_building_employment_hire_and_employee_mobility.inc"
#include "economy_runtime_building_employment_owner_reallocation.inc"
    }
    int64_t local_owner = 0;
    int64_t local_employee = 0;
    int64_t local_unemployed = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        local_owner = saturating_add(local_owner, population_store().owner_employed[slot],
                                     _saturation_count);
        local_employee = saturating_add(local_employee, population_store().employee_employed[slot],
                                        _saturation_count);
        const int64_t unemployed = std::max<int64_t>(
            0, population_store().population[slot] - population_store().owner_employed[slot] -
               population_store().employee_employed[slot]);
        local_unemployed = saturating_add(local_unemployed, unemployed, _saturation_count);
    });
    replace_employment_metrics_for_cell(
        cell, local_owner, local_employee, local_unemployed);
    bool employment_identity_valid = true;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        if (is_merchant_slot(slot)) return;
        const int32_t signature = static_cast<int32_t>(population_store().signature_id[slot]);
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size())) {
            employment_identity_valid = false;
            return;
        }
        // State-service cohorts (soldier) are emplaced by the state, not by a
        // local job seat: a barracks is a Military building, so these cohorts
        // never appear in the owner/employee employment lanes. They are audited
        // by Military (posts vs present), not by the local labour identity.
        if (profession_is_state_service_only(_signatures[signature].profession_id)) return;
        if (_signatures[signature].profession_id == _unemployed_profession_id) return;
        const int64_t employed = saturating_add(
            std::max<int64_t>(0, population_store().owner_employed[slot]),
            std::max<int64_t>(0, population_store().employee_employed[slot]),
            _saturation_count);
        if (employed != std::max<int64_t>(0, population_store().population[slot])) {
            employment_identity_valid = false;
        }
    });
    if (!employment_identity_valid) {
        error = "non_unemployed_cohort_has_idle_population";
        return false;
    }
    std::vector<EventLeg> event_legs;
    if (trace_detail) {
        for (size_t i = 0; i < trace_handles.size(); ++i) {
            int32_t slot = -1;
            if (!population_store().valid_handle(trace_handles[i], slot)) {
                // 璇?cohort 宸茶 A1 杩佺Щ瀹屽叏 drain锛堜緥濡傛暣鑱屼笟瑁佸厜杩涙睜骞堕噴鏀撅級锛?
                // 璁颁负褰掗浂 leg锛宻ubject 鐢ㄥ揩鐓?handle锛屼究浜庡璁￠棴鍚堛€?
                if (trace_owner_before[i] != 0) {
                    event_legs.push_back({FIELD_COHORT_OWNER_EMPLOYED, SUBJECT_COHORT,
                                          static_cast<int64_t>(trace_handles[i]), -1,
                                          trace_owner_before[i], 0});
                }
                if (trace_employee_before[i] != 0) {
                    event_legs.push_back({FIELD_COHORT_EMPLOYEE_EMPLOYED, SUBJECT_COHORT,
                                          static_cast<int64_t>(trace_handles[i]), -1,
                                          trace_employee_before[i], 0});
                }
                continue;
            }
            const int64_t handle = static_cast<int64_t>(trace_handles[i]);
            if (trace_owner_before[i] != population_store().owner_employed[slot]) {
                event_legs.push_back({FIELD_COHORT_OWNER_EMPLOYED, SUBJECT_COHORT, handle,
                                      -1, trace_owner_before[i],
                                      population_store().owner_employed[slot]});
            }
            if (trace_employee_before[i] != population_store().employee_employed[slot]) {
                event_legs.push_back({FIELD_COHORT_EMPLOYEE_EMPLOYED, SUBJECT_COHORT, handle,
                                      -1, trace_employee_before[i],
                                      population_store().employee_employed[slot]});
            }
        }
    }
    trace_append(EVENT_EMPLOYMENT_SETTLED,
                 static_cast<int32_t>(Stage::BUILDING_EMPLOYMENT), cell,
                 SUBJECT_BUILDING_GROUP, cell, first, last - first,
                 local_owner, local_employee, local_unemployed, last - first,
                 event_legs.empty() ? nullptr : &event_legs);
    EconomyCostProbe::record("employment.cell_hire", _current_day.get(),
                             elapsed_ms(employment_hire_started));
    EconomyCostProbe::record("employment.hire_ownerjob", _current_day.get(),
                             elapsed_ms(employment_ownerjob_started));
    EconomyCostProbe::record("employment.cell_total", _current_day.get(),
                             elapsed_ms(employment_cell_started));
    EconomyCostProbe::record("employment.candidate_scans", _current_day.get(),
                             0.0, static_cast<uint64_t>(
                                 std::max<int64_t>(0, employment_candidate_scans)));
    EconomyCostProbe::record("employment.pool_lookups", _current_day.get(),
                             0.0, static_cast<uint64_t>(
                                 std::max<int64_t>(0, employment_pool_lookups)));
    return true;
}

// Employment metrics/reconciliation implementations live in
// economy_runtime_building_employment.cpp.


} // namespace pk
