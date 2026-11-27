        // ---- 绗?姝?鏋愬嚭锛氭妸瓒呭嚭鐩爣鐨勫湪宀椾汉鍙ｈ縼寰€ unemployed|eth ----
        // (a) 鍏堟妸姣忎釜 group 鐨?filled_owner / _building_employee_filled 澶瑰埌鐩爣
        //     锛堣鍛橈細filled > target 鐨勫樊棰濋噴鏀撅級銆俥mployee 鎸?profession 绋冲畾搴?
        //     鍦ㄥ group 闂村墛鍑忥紙鍚?profession 鑱氬悎锛岄€?group 鍓婂埌 target锛夈€?
        // (b) 鍐嶆寜 profession|eth slot 鑱氬悎"璇?slot 搴斾繚鐣欑殑鍦ㄥ矖浜哄彛"锛屾妸
        //     population - retained 杩佸線 unemployed|eth銆?
        //
        // owner 渚уす绱э紙寤虹瓚椹卞姩锛氭瘡 group 鐙珛鎸夎嚜韬?filled-target 瑁侊級銆?
        EconomyCostProbe::record("employment.cell_targets", _current_day.get(),
                                 elapsed_ms(employment_migrate_started));
        employment_hire_started = Clock::now();
        const bool trace_employment = cell == _inspector_trace_cell;
        thread_local std::vector<int64_t> trace_filled_before_clamp;
        thread_local std::vector<int64_t> trace_filled_after_profession;
        if (trace_employment) {
            trace_filled_before_clamp.assign(
                static_cast<size_t>(std::max(0, last - first)), 0);
            trace_filled_after_profession.assign(
                static_cast<size_t>(std::max(0, last - first)), 0);
            for (int32_t g = first; g < last; ++g)
                trace_filled_before_clamp[g - first] = buildings_store().filled_owner[g];
        }
        for (int32_t g = first; g < last; ++g) {
            const auto group = building_view(static_cast<size_t>(g));
            if (group.cell != cell || group.count <= 0) continue;
            if (group.filled_owner > group_owner_target[g - first]) {
                building_at(static_cast<size_t>(g)).filled_owner =
                    group_owner_target[g - first];
            }
        }
        // A building's canonical owner signature describes its occupation, not an
        // ethnicity admission rule. Clamp aggregate owner fills by profession so
        // owners hired from another local ethnicity remain valid in the next pass.
        thread_local std::vector<int64_t> owner_remaining_by_profession;
        owner_remaining_by_profession.assign(professions, 0);
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const uint32_t sig = population_store().signature_id[slot];
            if (sig >= _signatures.size()) return;
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) return;
            owner_remaining_by_profession[profession] = saturating_add(
                owner_remaining_by_profession[profession],
                std::max<int64_t>(0, population_store().population[slot]),
                _saturation_count);
        });
        for (int32_t g : hire_order) {
            auto group = building_at(static_cast<size_t>(g));
            if (group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size())) {
                group.filled_owner = 0;
                continue;
            }
            const int32_t profession =
                _signatures[group.owner_signature_id].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) {
                group.filled_owner = 0;
                continue;
            }
            int64_t &remaining = owner_remaining_by_profession[profession];
            group.filled_owner = std::min(std::max<int64_t>(0, group.filled_owner), remaining);
            remaining -= group.filled_owner;
        }
        if (trace_employment) {
            for (int32_t g = first; g < last; ++g)
                trace_filled_after_profession[g - first] =
                    buildings_store().filled_owner[g];
        }
        // Family ownership is a sparse attribution overlay on the aggregated
        // building group, not an admission rule: it records which families the
        // seated proprietors belong to, and never reduces the fill.
        // Track B (user-approved): refresh this slow-moving attribution overlay
        // every N days; stale shares are carried in between.
        static const bool attribution_track_b_enabled = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B);
            return !(value && std::strcmp(value, "0") == 0);
        }();
        static const int32_t attribution_cadence = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_FAMILY_ATTRIBUTION_CADENCE);
            const int32_t parsed = value ? std::atoi(value) : 0;
            return parsed > 0 ? std::min<int32_t>(parsed, 30) : 5;
        }();
        static const int32_t attribution_spread = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_FAMILY_ATTRIBUTION_SPREAD);
            const int32_t parsed = value ? std::atoi(value) : 0;
            return parsed > 0 ? std::min<int32_t>(parsed, 32) : 1;
        }();
        bool attribution_due = true;
        if (attribution_track_b_enabled && attribution_spread > 1) {
            const int32_t attribution_phase = static_cast<int32_t>(
                ((_current_day.get() % attribution_spread) +
                 attribution_spread) % attribution_spread);
            attribution_due = cell >= 0 && (cell % attribution_spread) ==
                attribution_phase;
        } else if (attribution_track_b_enabled && attribution_cadence > 1) {
            attribution_due = (_current_day.get() % attribution_cadence) == 0;
        }
        if (attribution_due) {
            attribute_family_owner_employment_for_cell(cell);
        } else {
            EconomyCostProbe::record("family.track_b_attribution_skip",
                                     _current_day.get(), 0.0, 1u);
        }
        // employee 渚уす绱э細profession p 鑻?危filled > 危target锛屾寜 group 绋冲畾搴?
        // 浠庡悗寰€鍓嶅墛鍑忓悇 role fill 鍒?demand銆傜敤 remaining[p] 杩借釜璇?profession
        // 鍏佽淇濈暀鐨勬€诲湪宀楁暟锛岄€?group 鍒嗛厤 min(role_filled, remaining)銆?
        thread_local std::vector<int64_t> emp_remaining;   // 姣?profession 鍏佽淇濈暀鐨勫湪宀椾笂闄?
        emp_remaining.assign(professions, 0);
        for (int32_t p = 0; p < professions; ++p) {
            emp_remaining[p] = std::min(fill[p], demand[p]);   // 瑁佸憳鍚庝繚鐣?= min(鍦ㄥ矖, 鐩爣)
        }
        std::fill(fill.begin(), fill.end(), 0);   // 閲嶇畻涓哄す绱у悗鐨勫疄闄呭湪宀?
        for (int32_t g = first; g < last; ++g) {
            auto group = building_view(static_cast<size_t>(g));
            if (group.cell != cell || group.count <= 0) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t p = role.profession_id;
                const int32_t fi = group.employee_fill_begin + r;
                const int64_t cur = std::max<int64_t>(0, _building_employee_filled[fi]);
                const int64_t keep = std::min(cur, emp_remaining[p]);
                _building_employee_filled.write_scalar(fi, keep, market_mutation_sink());
                emp_remaining[p] -= keep;
                fill[p] = saturating_add(fill[p], keep, _saturation_count);
            }
        }

        // (b) 璁＄畻姣忎釜 profession|eth slot 澶圭揣鍚庡簲淇濈暀鐨勫湪宀椾汉鍙ｏ紝鏀堕泦杩佸線姹犵殑宸銆?
        //     owner_retained[slot] = 璇?signature 鍚?group filled_owner 涔嬪拰锛?
        //     employee_retained[slot] = 璇?profession 鍦ㄥ矖 employee 鎸?slot 绋冲畾搴忔憡娲俱€?
        //     retained = owner_retained + employee_retained锛圓1: <= population锛夈€?
        //     surplus = population - retained 鈫?杩佸線 unemployed|eth銆?
        //
        // First aggregate filled owner jobs by profession, then distribute them
        // over local profession|ethnicity cohorts in stable signature order. A
        // BuildingGroup has no per-owner identity, so retaining by its canonical
        // signature would recreate an ethnicity partition after every pass.
        thread_local std::vector<int64_t> sig_owner_retained;
        thread_local std::vector<int64_t> sig_owner_population;
        thread_local std::vector<int64_t> owner_filled_by_profession;
        thread_local std::vector<int64_t> owner_population_by_profession;
        thread_local std::vector<int64_t> owner_prefix_by_profession;
        thread_local std::vector<int64_t> owner_distributed_by_profession;
        thread_local std::vector<int32_t> owner_active_signatures;
        thread_local std::vector<int64_t> sig_owner_distributed;
        // 杩欎笁鏉?signature 閫氶亾鍘熸潵鍦ㄦ瘡鏍煎紑澶村悇 assign 涓€閬嶆暣寮?_signatures 琛ㄣ€傝〃闅?
        // 瀛樻。鍗曡皟澧為暱涓旀案涓嶆敹缂╋紝鑰屾瘡鏍煎疄闄呰Е纰扮殑 signature 鍙湁鏈湴鍑犱釜銆俫eneration
        // stamp 璁╂棫鍊艰嚜鍔ㄥけ鏁堬細stamp 鏈懡涓殑妲戒綅涓€寰嬭涓?0锛屼笌娓呰〃鍚庣殑璇绘硶涓€鑷淬€?
        thread_local std::vector<uint32_t> sig_owner_stamp;
        thread_local uint32_t sig_owner_generation = 0;
        ++sig_owner_generation;
        if (sig_owner_stamp.size() < _signatures.size()) {
            sig_owner_retained.resize(_signatures.size(), 0);
            sig_owner_population.resize(_signatures.size(), 0);
            sig_owner_distributed.resize(_signatures.size(), 0);
            sig_owner_stamp.resize(_signatures.size(), 0);
        }
        if (sig_owner_generation == 0) {
            std::fill(sig_owner_stamp.begin(), sig_owner_stamp.end(), 0);
            sig_owner_generation = 1;
        }
        owner_filled_by_profession.assign(professions, 0);
        owner_population_by_profession.assign(professions, 0);
        owner_prefix_by_profession.assign(professions, 0);
        owner_distributed_by_profession.assign(professions, 0);
        owner_active_signatures.clear();
        for (int32_t g = first; g < last; ++g) {
            auto group = building_view(static_cast<size_t>(g));
            if (group.cell != cell || group.count <= 0) continue;
            if (group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size())) continue;
            const int32_t profession =
                _signatures[group.owner_signature_id].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) continue;
            owner_filled_by_profession[profession] = saturating_add(
                owner_filled_by_profession[profession],
                std::max<int64_t>(0, group.filled_owner), _saturation_count);
        }
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t sig = static_cast<int32_t>(population_store().signature_id[slot]);
            if (sig < 0 || sig >= static_cast<int32_t>(_signatures.size())) return;
            const int32_t profession = _signatures[sig].profession_id;
            if (profession < 0 || profession >= professions ||
                profession == _unemployed_profession_id) return;
            if (sig_owner_stamp[sig] != sig_owner_generation) {
                sig_owner_stamp[sig] = sig_owner_generation;
                sig_owner_population[sig] = 0;
                sig_owner_retained[sig] = 0;
                sig_owner_distributed[sig] = 0;
            }
            if (sig_owner_population[sig] == 0) owner_active_signatures.push_back(sig);
            const int64_t population = std::max<int64_t>(0,
                population_store().population[slot]);
            sig_owner_population[sig] = saturating_add(sig_owner_population[sig],
                population, _saturation_count);
            owner_population_by_profession[profession] = saturating_add(
                owner_population_by_profession[profession], population,
                _saturation_count);
        });
        std::sort(owner_active_signatures.begin(), owner_active_signatures.end());
        for (const int32_t sig : owner_active_signatures) {
            const int32_t profession = _signatures[sig].profession_id;
            owner_prefix_by_profession[profession] = saturating_add(
                owner_prefix_by_profession[profession], sig_owner_population[sig],
                _saturation_count);
            const int64_t next = owner_population_by_profession[profession] > 0
                ? mul_div_sat(owner_filled_by_profession[profession],
                    owner_prefix_by_profession[profession],
                    owner_population_by_profession[profession], _saturation_count)
                : 0;
            sig_owner_retained[sig] = std::max<int64_t>(0,
                next - owner_distributed_by_profession[profession]);
            owner_distributed_by_profession[profession] = next;
        }
        // employee 鍦ㄥ矖鎸?profession 绋冲畾搴忔憡娲惧埌鍚?slot锛堝悓 profession 鐨勫 eth
        // slot 鎸?signature_id 鍗囧簭锛岀敤 cohort 鍙绾抽噺姣斾緥鎽婃淳锛屽墠缂€鍜屼繚纭畾锛夈€?
        thread_local std::vector<int64_t> emp_prefix;
        thread_local std::vector<int64_t> emp_distributed;
        thread_local std::vector<int64_t> emp_capacity;   // 姣?profession 鍚?slot 鍙綋 employee 鐨勫閲忎箣鍜?
        emp_prefix.assign(professions, 0);
        emp_distributed.assign(professions, 0);
        emp_capacity.assign(professions, 0);
        // 绗竴閬嶏細绠楁瘡 profession 鐨?employee 瀹归噺鎬婚噺 = 危(population - owner_retained)銆?
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) return;
            const int32_t sig = static_cast<int32_t>(population_store().signature_id[slot]);
            const int32_t p = _signatures[sig].profession_id;
            if (p == _unemployed_profession_id) return;
            const int64_t retained_here = sig_owner_stamp[sig] == sig_owner_generation
                ? sig_owner_retained[sig] : 0;
            const int64_t owner_here = std::min(retained_here,
                std::max<int64_t>(0, population_store().population[slot]));
            const int64_t cap = std::max<int64_t>(0, population_store().population[slot] - owner_here);
            emp_capacity[p] = saturating_add(emp_capacity[p], cap, _saturation_count);
        });
        // 绗簩閬嶏細鍙鏀堕泦姣忎釜 slot 鐨?surplus锛堣縼寰€姹狅級鍒扮紦鍐诧紝閬嶅巻鍚庣粺涓€杩佺Щ銆?
        // owner_retained 鎸?signature 鍦ㄥ slot 闂翠篃闇€绋冲畾搴忔憡娲撅紙鍚?signature 閫氬父
        // 鍙湁涓€涓?slot锛涘椤垫椂鎸夐亶鍘嗗簭锛屽墠缂€鍜屼繚纭畾锛夈€?
        thread_local std::vector<int32_t> shed_source_slots;   // surplus 鏉ユ簮 slot
        thread_local std::vector<int32_t> shed_dest_eth;       // 瀵瑰簲 eth锛堚啋 unemployed|eth锛?
        thread_local std::vector<int64_t> shed_pop;            // surplus 浜烘暟
        shed_source_slots.clear(); shed_dest_eth.clear(); shed_pop.clear();
        // Route B: merchant slots are no longer skipped wholesale. A merchant
        // slot may now carry a merchant-post owner (sig_owner_retained>0) that
        // must be aggregated/right-sized like any other owner. But the market
        // maker invariant (rebuild_merchant_ranges requires >=1 merchant per
        // populated cell) forbids shedding the last merchant, so a merchant
        // slot keeps a floor of max(owner_here, 1) retained. Non-merchant slots
        // are unchanged.
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t sig = static_cast<int32_t>(population_store().signature_id[slot]);
            const int32_t p = _signatures[sig].profession_id;
            const int32_t eth = _signatures[sig].ethnicity_id;
            const int64_t pop = std::max<int64_t>(0, population_store().population[slot]);
            if (p == _unemployed_profession_id) {
                // 澶变笟 slot锛氭湰姝ヤ笉鍔紙瀹冩槸姹狅紝鎷涗汉姝ラ鎵嶄粠涓縼鍑猴級銆?
                return;
            }
            const bool merchant_here = is_merchant_slot(slot);
            // Military v1 (design §5.4): state-service professions are never
            // laid off for over-capacity. A soldier cohort keeps its identity
            // and headcount; the building simply stops hiring.
            const bool state_service_here =
                profession_is_state_service_only(p);
            // owner 鍦ㄦ湰 slot 鐨勪唤棰濓紙鍚?signature 澶?slot 鏃剁ǔ瀹氬簭鎽婃淳锛夈€?
            const bool sig_active = sig_owner_stamp[sig] == sig_owner_generation;
            const int64_t retained_here = sig_active ? sig_owner_retained[sig] : 0;
            const int64_t distributed_here = sig_active ? sig_owner_distributed[sig] : 0;
            const int64_t owner_here = std::min(
                std::max<int64_t>(0, retained_here - distributed_here), pop);
            if (sig_active)
                sig_owner_distributed[sig] = saturating_add(distributed_here,
                                                            owner_here, _saturation_count);
            if (merchant_here) {
                // 鍟嗕汉 slot 涓嶅仛 employee锛堜粎 owner 宀楋級锛涗繚搴?1 涓仛甯傚晢涓嶈銆?
                const int64_t retained = std::min(pop,
                    std::max<int64_t>(owner_here, pop > 0 ? 1 : 0));
                population_store().owner_employed.write_scalar(slot, owner_here, market_mutation_sink());
                population_store().employee_employed.write_scalar(slot, 0, market_mutation_sink());
                const int64_t surplus = std::max<int64_t>(0, pop - retained);
                if (surplus > 0 && eth >= 0 && eth < n_eth) {
                    shed_source_slots.push_back(slot);
                    shed_dest_eth.push_back(eth);
                    shed_pop.push_back(surplus);
                }
                return;
            }
            // employee 鍦ㄦ湰 slot 鐨勪唤棰濓細鎸夊閲忔瘮渚嬫憡娲?fill[p]銆?
            const int64_t cap_here = std::max<int64_t>(0, pop - owner_here);
            emp_prefix[p] = saturating_add(emp_prefix[p], cap_here, _saturation_count);
            const int64_t emp_next = emp_capacity[p] > 0
                ? mul_div_sat(fill[p], emp_prefix[p], emp_capacity[p], _saturation_count) : 0;
            const int64_t emp_here = std::max<int64_t>(0, emp_next - emp_distributed[p]);
            emp_distributed[p] = emp_next;
            const int64_t retained = std::min(pop, saturating_add(owner_here, emp_here,
                                                                   _saturation_count));
            population_store().owner_employed.write_scalar(slot, owner_here, market_mutation_sink());
            population_store().employee_employed.write_scalar(slot, std::min(emp_here,
                std::max<int64_t>(0, pop - owner_here)), market_mutation_sink());
            const int64_t surplus = state_service_here
                ? int64_t{0}
                : std::max<int64_t>(0, pop - retained);
            if (surplus > 0 && eth >= 0 && eth < n_eth) {
                shed_source_slots.push_back(slot);
                shed_dest_eth.push_back(eth);
                shed_pop.push_back(surplus);
            }
        });
        // Signature must be read before the moves below rewrite the slots.
        thread_local std::vector<int64_t> trace_shed_by_signature;
        if (trace_employment) {
            trace_shed_by_signature.assign(_signatures.size(), 0);
            for (size_t i = 0; i < shed_source_slots.size(); ++i) {
                const int32_t sig = static_cast<int32_t>(
                    population_store().signature_id[shed_source_slots[i]]);
                if (sig >= 0 && sig < static_cast<int32_t>(_signatures.size()))
                    trace_shed_by_signature[sig] += shed_pop[i];
            }
        }
        // 閬嶅巻澶栨墽琛屾瀽鍑鸿縼绉伙紙鍦ㄥ矖 profession|eth 鈫?unemployed|eth锛夈€?
        for (size_t i = 0; i < shed_source_slots.size(); ++i) {
            const int32_t src = shed_source_slots[i];
            const int32_t dest_sig = unemployed_signature_for_ethnicity(shed_dest_eth[i]);
            if (dest_sig < 0) continue;   // 鏃?unemployed signature锛堝悜鍚庡吋瀹癸級锛氱暀鍘?slot銆?
            if (dest_sig == static_cast<int32_t>(population_store().signature_id[src])) continue;
            bool drained = false;
            if (!move_cohort_population(src, cell, dest_sig, shed_pop[i], error, &drained)) {
                return false;
            }
        }
