void NativeEconomyRuntime::rebuild_family_indices(bool rebuild_derived) {
    const auto membership_started = Clock::now();
    const auto membership_erase_started = Clock::now();
    family_memberships().erase_if(
        [&](const FamilyMembershipEdge &edge) {
            int32_t family = -1, slot = -1;
            return edge.people <= 0 ||
                !families_store().valid_handle(edge.family_handle, family) ||
                !population_store().valid_handle(edge.cohort_handle, slot);
        });
    EconomyCostProbe::record("family.rebuild.membership_erase", _current_day.get(),
                             elapsed_ms(membership_erase_started));
    const auto membership_before = family_memberships().begin();
    const auto membership_after = family_memberships().end();
    const auto membership_less = [](const FamilyMembershipEdge &a,
                                    const FamilyMembershipEdge &b) {
        return std::tie(a.cohort_handle, a.family_handle) <
            std::tie(b.cohort_handle, b.family_handle);
    };
    // Steady-state rebuilds see an already sorted, duplicate-free ledger. The
    // container's sort()/swap() re-encode every row through the audited column,
    // so skip them when the order and keys are unchanged.
    if (!std::is_sorted(membership_before, membership_after, membership_less))
        family_memberships().sort(membership_less);
    bool membership_has_duplicates = false;
    for (size_t i = 1; i < family_memberships().size(); ++i) {
        if (family_memberships()[i - 1].cohort_handle ==
                family_memberships()[i].cohort_handle &&
            family_memberships()[i - 1].family_handle ==
                family_memberships()[i].family_handle) {
            membership_has_duplicates = true;
            break;
        }
    }
    if (membership_has_duplicates) {
        std::vector<FamilyMembershipEdge> merged_memberships;
        merged_memberships.reserve(family_memberships().size());
        for (const FamilyMembershipEdge &edge : family_memberships()) {
            if (!merged_memberships.empty() &&
                merged_memberships.back().cohort_handle == edge.cohort_handle &&
                merged_memberships.back().family_handle == edge.family_handle) {
                FamilyMembershipEdge &dst = merged_memberships.back();
                dst.people += edge.people;
                dst.cash_claim += edge.cash_claim;
                dst.population_basis = std::max(dst.population_basis,
                                                edge.population_basis);
                dst.funds_basis = std::max(dst.funds_basis, edge.funds_basis);
                // Employment is recomputed later; keep merge-only edges basis-valid.
                dst.owner_employed = 0;
                dst.employee_employed = 0;
                sanitize_family_membership_edge(dst);
            } else {
                merged_memberships.push_back(edge);
            }
        }
        family_memberships().swap(merged_memberships);
    }
    EconomyCostProbe::record("family.rebuild.membership_merge", _current_day.get(),
                             elapsed_ms(membership_erase_started));

    _family_member_offsets.assign(families_store().active.size() + 1, 0);
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        int32_t family = -1;
        if (families_store().valid_handle(edge.family_handle, family))
            ++_family_member_offsets[static_cast<size_t>(family) + 1];
    }
    for (size_t i = 0; i + 1 < _family_member_offsets.size(); ++i)
        _family_member_offsets[i + 1] += _family_member_offsets[i];
    _family_member_edge_indices.assign(family_memberships().size(), -1);
    std::vector<int32_t> family_member_cursor(_family_member_offsets.begin(),
                                               _family_member_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(family_memberships().size()); ++i) {
        int32_t family = -1;
        if (families_store().valid_handle(family_memberships()[i].family_handle, family))
            _family_member_edge_indices[family_member_cursor[family]++] = i;
    }

    EconomyCostProbe::record("family.rebuild.membership_csr", _current_day.get(),
                             elapsed_ms(membership_started));
    _rebuild_family_membership_ms += elapsed_ms(membership_started);
    const auto ownership_started = Clock::now();
    // Nothing below mutates the group lane, so the shared handle index stays valid
    // for the whole rebuild and we avoid re-hashing every building group.
    const std::unordered_map<uint64_t, int32_t> &building_by_handle =
        building_handle_index();
    family_ownerships().erase_if(
        [&](const FamilyBuildingOwnership &edge) {
            int32_t family = -1;
            return edge.owned_count <= 0 ||
                !families_store().valid_handle(edge.family_handle, family) ||
                building_by_handle.find(edge.building_handle) ==
                    building_by_handle.end();
        });
    const auto ownership_less = [](const FamilyBuildingOwnership &a,
                                   const FamilyBuildingOwnership &b) {
        return std::tie(a.building_handle, a.family_handle) <
            std::tie(b.building_handle, b.family_handle);
    };
    if (!std::is_sorted(family_ownerships().begin(), family_ownerships().end(),
                        ownership_less))
        family_ownerships().sort(ownership_less);
    bool ownership_has_duplicates = false;
    for (size_t i = 1; i < family_ownerships().size(); ++i) {
        if (family_ownerships()[i - 1].building_handle ==
                family_ownerships()[i].building_handle &&
            family_ownerships()[i - 1].family_handle ==
                family_ownerships()[i].family_handle) {
            ownership_has_duplicates = true;
            break;
        }
    }
    if (ownership_has_duplicates) {
        std::vector<FamilyBuildingOwnership> merged_ownerships;
        merged_ownerships.reserve(family_ownerships().size());
        for (const FamilyBuildingOwnership &edge : family_ownerships()) {
            if (!merged_ownerships.empty() &&
                merged_ownerships.back().building_handle == edge.building_handle &&
                merged_ownerships.back().family_handle == edge.family_handle) {
                merged_ownerships.back().owned_count += edge.owned_count;
                merged_ownerships.back().filled_owner += edge.filled_owner;
            } else {
                merged_ownerships.push_back(edge);
            }
        }
        family_ownerships().swap(merged_ownerships);
    }
    const auto ownership_sanitize_started = Clock::now();
    sanitize_family_ownership_edges();
    EconomyCostProbe::record("family.rebuild.ownership_sanitize", _current_day.get(),
                             elapsed_ms(ownership_sanitize_started));

    _family_owned_offsets.assign(families_store().active.size() + 1, 0);
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        int32_t family = -1;
        if (families_store().valid_handle(edge.family_handle, family))
            ++_family_owned_offsets[static_cast<size_t>(family) + 1];
    }
    for (size_t i = 0; i + 1 < _family_owned_offsets.size(); ++i)
        _family_owned_offsets[i + 1] += _family_owned_offsets[i];
    _family_owned_edge_indices.assign(family_ownerships().size(), -1);
    std::vector<int32_t> family_owned_cursor(_family_owned_offsets.begin(),
                                              _family_owned_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(family_ownerships().size()); ++i) {
        int32_t family = -1;
        if (families_store().valid_handle(family_ownerships().read_at(i, __FILE__, __LINE__).family_handle, family))
            _family_owned_edge_indices[family_owned_cursor[family]++] = i;
    }

    EconomyCostProbe::record("family.rebuild.ownership_block", _current_day.get(),
                             elapsed_ms(ownership_started));
    _rebuild_family_ownership_ms += elapsed_ms(ownership_started);
    const auto csr_started = Clock::now();
    _family_cohort_offsets.assign(population_store().active.size() + 1, 0);
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        int32_t slot = -1;
        if (population_store().valid_handle(edge.cohort_handle, slot))
            ++_family_cohort_offsets[static_cast<size_t>(slot) + 1];
    }
    for (size_t i = 0; i + 1 < _family_cohort_offsets.size(); ++i)
        _family_cohort_offsets[i + 1] += _family_cohort_offsets[i];
    _family_cohort_edge_indices.assign(family_memberships().size(), -1);
    std::vector<int32_t> cohort_cursor(_family_cohort_offsets.begin(),
                                       _family_cohort_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(family_memberships().size()); ++i) {
        int32_t slot = -1;
        if (population_store().valid_handle(family_memberships()[i].cohort_handle, slot))
            _family_cohort_edge_indices[cohort_cursor[slot]++] = i;
    }

    _family_building_offsets.assign(building_count() + 1, 0);
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        const auto it = building_by_handle.find(edge.building_handle);
        if (it != building_by_handle.end())
            ++_family_building_offsets[static_cast<size_t>(it->second) + 1];
    }
    for (size_t i = 0; i + 1 < _family_building_offsets.size(); ++i)
        _family_building_offsets[i + 1] += _family_building_offsets[i];
    _family_building_edge_indices.assign(family_ownerships().size(), -1);
    std::vector<int32_t> building_cursor(_family_building_offsets.begin(),
                                         _family_building_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(family_ownerships().size()); ++i) {
        const auto it = building_by_handle.find(family_ownerships().read_at(i, __FILE__, __LINE__).building_handle);
        if (it != building_by_handle.end())
            _family_building_edge_indices[building_cursor[it->second]++] = i;
    }

    _rebuild_family_csr_ms += elapsed_ms(csr_started);
    const auto cell_index_started = Clock::now();
    std::vector<std::pair<int32_t, int32_t>> cell_family;
    cell_family.reserve(family_memberships().size());
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        int32_t slot = -1, family = -1;
        if (!population_store().valid_handle(edge.cohort_handle, slot) ||
            !families_store().valid_handle(edge.family_handle, family)) continue;
        const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
        if (cell >= 0) cell_family.emplace_back(cell, family);
    }
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        int32_t family = -1;
        const auto building = building_by_handle.find(edge.building_handle);
        if (!families_store().valid_handle(edge.family_handle, family) ||
            building == building_by_handle.end()) continue;
        const int32_t cell = buildings_store().cell[building->second];
        if (cell >= 0) cell_family.emplace_back(cell, family);
    }
    std::sort(cell_family.begin(), cell_family.end());
    cell_family.erase(std::unique(cell_family.begin(), cell_family.end()),
                      cell_family.end());
    _family_cell_offsets.assign(static_cast<size_t>(_cell_count.get()) + 1, 0);
    for (const auto &item : cell_family)
        ++_family_cell_offsets[static_cast<size_t>(item.first) + 1];
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell)
        _family_cell_offsets[cell + 1] += _family_cell_offsets[cell];
    _family_cell_indices.clear();
    _family_cell_indices.reserve(cell_family.size());
    for (const auto &item : cell_family) _family_cell_indices.push_back(item.second);
    _rebuild_family_cellindex_ms += elapsed_ms(cell_index_started);
    if (rebuild_derived) {
        rebuild_family_industry_metrics();
        rebuild_family_owned_output_csr();
    }
    _family_csr_edge_count = family_memberships().size();
    _family_indices_dirty = false;
}

void NativeEconomyRuntime::normalize_family_memberships(bool rebuild_derived,
                                                        bool commit_ledger) {
    // This is the one mandatory rebuild per commit. It runs after all
    // population and building changes for the epoch, so it is what prunes
    // edges orphaned by cohort release or building demolition. The later
    // rebuilds in the commit are gated on the dirty flag and rely on it.
    const auto family_normalize_started = Clock::now();
    rebuild_family_indices(rebuild_derived);
    const double family_normalize_rebuild_ms =
        elapsed_ms(family_normalize_started);
    // Membership counts are attributed event by event (births, deaths,
    // moves), so this pass only enforces the down-caps. The claim ledger
    // settles once per commit: business profit by staffed owner posts, the
    // remaining cohort cash delta per capita.
    const auto family_normalize_ledger_started = Clock::now();
    if (commit_ledger) settle_family_claim_ledger();
    const double family_normalize_ledger_ms =
        elapsed_ms(family_normalize_ledger_started);
    const bool has_business = commit_ledger &&
        _family_ledger_business_by_edge.size() == family_memberships().size();
    bool rescale_emptied_edge = false;
    size_t begin = 0;
    while (begin < family_memberships().size()) {
        size_t end = begin + 1;
        while (end < family_memberships().size() &&
               family_memberships()[end].cohort_handle ==
                   family_memberships()[begin].cohort_handle) ++end;
        int32_t slot = -1;
        if (!population_store().valid_handle(
                family_memberships()[begin].cohort_handle, slot)) {
            begin = end;
            continue;
        }
        const int64_t current_pop = std::max<int64_t>(0,
            population_store().population[slot]);
        const int64_t current_funds = std::max<int64_t>(0,
            population_store().funds[slot]);
        int64_t old_people = 0, funds_basis = 0;
        for (size_t i = begin; i < end; ++i) {
            old_people += std::max<int64_t>(0, family_memberships()[i].people);
            funds_basis = std::max(funds_basis, family_memberships()[i].funds_basis);
        }
        const bool cap_people = old_people > current_pop;
        if (cap_people) ++_family_reconcile_corrections;
        int64_t remainder = 0;
        if (commit_ledger) {
            const int64_t business = static_cast<size_t>(slot) <
                    _family_ledger_business_by_slot.size()
                ? _family_ledger_business_by_slot[slot] : 0;
            remainder = saturating_sub(saturating_sub(current_funds, funds_basis,
                _saturation_count), business, _saturation_count);
        }
        int64_t people_prefix = 0, people_done = 0, claim_total = 0;
        for (size_t i = begin; i < end; ++i) {
            // Compute against the read-only row first and only take the mutable
            // lease when a field actually changes: on a steady day most edges
            // keep identical claim/basis values, and the per-column audit
            // preimage borrow dominated this pass.
            const FamilyMembershipEdge &edge_view = family_memberships()[i];
            const int64_t people_before = std::max<int64_t>(0, edge_view.people);
            int64_t next_people = people_before;
            if (cap_people) {
                people_prefix += people_before;
                const int64_t next_target = mul_div_sat(current_pop, people_prefix,
                    old_people, _saturation_count);
                next_people = std::max<int64_t>(0, next_target - people_done);
                people_done = next_target;
            }
            int64_t next_claim = edge_view.cash_claim;
            int64_t next_funds_basis = edge_view.funds_basis;
            int64_t next_population_basis = edge_view.population_basis;
            if (commit_ledger) {
                int64_t claim = std::max<int64_t>(0, edge_view.cash_claim);
                if (has_business)
                    claim = saturating_add(claim, _family_ledger_business_by_edge[i],
                                           _saturation_count);
                if (current_pop > 0 && remainder != 0)
                    claim = saturating_add(claim, mul_div_sat(remainder,
                        people_before, current_pop, _saturation_count),
                        _saturation_count);
                next_claim = claim;
                next_funds_basis = current_funds;
                next_population_basis = current_pop;
            }
            next_claim = next_people > 0
                ? std::max<int64_t>(0, next_claim) : 0;
            claim_total = saturating_add(claim_total, next_claim, _saturation_count);
            const bool changed = next_people != edge_view.people ||
                next_claim != edge_view.cash_claim ||
                next_funds_basis != edge_view.funds_basis ||
                next_population_basis != edge_view.population_basis ||
                edge_view.owner_employed != 0 ||
                edge_view.employee_employed != 0;
            if (changed) {
                auto edge_write = family_memberships().edit_row(i,
                    market_mutation_sink());
                FamilyMembershipEdge &edge = edge_write[0];
                edge.people = next_people;
                edge.cash_claim = next_claim;
                edge.funds_basis = next_funds_basis;
                edge.population_basis = next_population_basis;
                edge.owner_employed = 0;
                edge.employee_employed = 0;
            }
            if (people_before > 0 && next_people <= 0) rescale_emptied_edge = true;
        }
        if (claim_total > current_funds) {
            ++_family_ledger_clamps;
            int64_t claim_prefix = 0, claim_done = 0;
            for (size_t i = begin; i < end; ++i) {
                auto edge_write = family_memberships().edit_row(i, market_mutation_sink());
                FamilyMembershipEdge &edge = edge_write[0];
                claim_prefix += edge.cash_claim;
                const int64_t next_claim = mul_div_sat(current_funds, claim_prefix,
                    claim_total, _saturation_count);
                edge.cash_claim = std::max<int64_t>(0, next_claim - claim_done);
                claim_done = next_claim;
            }
        }
        begin = end;
    }
    for (int32_t slot : _family_ledger_touched_slots)
        if (static_cast<size_t>(slot) < _family_ledger_business_by_slot.size())
            _family_ledger_business_by_slot[slot] = 0;
    _family_ledger_touched_slots.clear();
    EconomyCostProbe::record("family.normalize.rebuild_ms", _current_day.get(),
                             family_normalize_rebuild_ms);
    EconomyCostProbe::record("family.normalize.ledger_ms", _current_day.get(),
                             family_normalize_ledger_ms);
    EconomyCostProbe::record("family.normalize.caps_ms", _current_day.get(),
                             elapsed_ms(family_normalize_started) -
                                 family_normalize_rebuild_ms -
                                 family_normalize_ledger_ms);
    // Capping never adds, removes or reorders edges, so the CSR built above
    // stays exact unless an edge was emptied and now has to be pruned.
    if (rescale_emptied_edge) {
        _family_indices_dirty = true;
        rebuild_family_indices(rebuild_derived);
    }
}
