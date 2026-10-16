from pathlib import Path
p=Path('gdext/src/economy_runtime.cpp')
s=p.read_text(encoding='utf-8')
a=s.index('void NativeEconomyRuntime::split_family_branches()')
b=s.index('\n}',a)+2
old=s[a:b]
traits=old[old.index('        // A split deliberately'):old.index('        family_trait_rolls().insert')]
traits=traits.replace('family_trait_context_allows(trait_id, child)', '(family_trait_technology_unlocked(trait_id, cell) &&\n                family_trait_origin_gates_allow(trait_id, cell))')
traits=traits.replace('child_handle', 'uint64_t{0}')
transfer=old[old.index('        const size_t membership_count'):old.index('        // A split deliberately')]
transfer=transfer.replace('candidate.cell', 'cell')
gifts=old[old.index('        if ((split_flags & (FAMILY_FLAG_SPLIT_GIFT_BUILDING'):old.index('        _family_indices_dirty = true;',old.index('        if ((split_flags & (FAMILY_FLAG_SPLIT_GIFT_BUILDING'))]
gifts=gifts.replace('candidate.cell','offer.cell')
new='''bool NativeEconomyRuntime::build_family_split_offer(
        int32_t parent, int32_t cell, FamilyFoundingOffer &offer) const {
    if (parent < 0 || parent >= static_cast<int32_t>(families_store().active.size()) ||
        families_store().active[parent] == 0 || cell < 0 || cell >= _cell_count.get() ||
        cell == families_store().origin_cell[parent]) return false;
    int64_t people = 0;
    const uint64_t parent_handle = families_store().handle_for_index(parent);
    for (int32_t p = _family_member_offsets[parent]; p < _family_member_offsets[parent + 1]; ++p) {
        const auto &edge = family_memberships()[_family_member_edge_indices[p]];
        int32_t slot = -1;
        if (population_store().valid_handle(edge.cohort_handle, slot) &&
            population_store().page_cell[slot / COHORT_PAGE_SIZE] == cell)
            people += edge.people;
    }
    if (people < _family_split_population_threshold.get()) return false;
    offer.cell = cell;
    offer.source_family_handle = parent_handle;
    offer.milestone_population = _family_split_population_threshold.get();
    offer.created_day = _current_day.get();
    std::vector<int32_t> used_effects;
    for (int32_t card = 0; card < FAMILY_FOUNDING_CARD_COUNT; ++card) {
        uint64_t identity = 1469598103934665603ULL;
        identity = trace_hash_mix(identity, static_cast<uint64_t>(_seed.get()));
        identity = trace_hash_mix(identity, static_cast<uint64_t>(families_store().stable_id[parent]));
        identity = trace_hash_mix(identity, static_cast<uint32_t>(cell));
        identity = trace_hash_mix(identity, families_store().split_sequence[parent]);
        identity = trace_hash_mix(identity, static_cast<uint64_t>(_family_catalog_hash.get()));
        identity = trace_hash_mix(identity, static_cast<uint32_t>(card));
        identity = trace_hash_mix(identity, static_cast<uint64_t>(_next_family_founding_offer_id.get()));
        int64_t child_stable = static_cast<int64_t>((identity & 0x7fffffffffffffffULL) | 1ULL);
        for (uint64_t probe = 1; _family_stable_ids.count(child_stable) != 0; ++probe)
            child_stable = static_cast<int64_t>((trace_hash_mix(identity, probe) & 0x7fffffffffffffffULL) | 1ULL);
'''+traits+'''
        FamilyFoundingCandidate candidate;
        candidate.stable_id = child_stable;
        candidate.surname_id = families_store().surname_id[parent];
        candidate.culture_group_id = families_store().culture_group_id[parent];
        candidate.founders = people;
        for (const auto &roll : child_traits) {
            candidate.trait_ids.push_back(roll.trait_id);
            candidate.trait_strength_q16.push_back(roll.strength_q16);
        }
        // Freeze a complete proposal; the UI never rolls traits or effects.
        candidate.effect_id = roll_random_pool_family_effect(
            static_cast<uint64_t>(child_stable), cell, &used_effects);
        if (candidate.effect_id >= 0) used_effects.push_back(candidate.effect_id);
        for (int32_t p = _family_owned_offsets[parent]; p < _family_owned_offsets[parent + 1]; ++p) {
            const auto &ownership = family_ownerships()[_family_owned_edge_indices[p]];
            const int32_t group = building_index_for_handle(ownership.building_handle);
            if (group < 0 || buildings_store().cell[group] != cell || ownership.owned_count <= 0) continue;
            candidate.building_handle = ownership.building_handle;
            candidate.building_type_id = buildings_store().type_id[group];
            candidate.owner_signature_id = buildings_store().owner_signature_id[group];
            break;
        }
        offer.candidates.push_back(std::move(candidate));
    }
    return !offer.candidates.empty();
}

void NativeEconomyRuntime::transfer_family_branch(int32_t parent, int32_t child, int32_t cell) {
    const uint64_t parent_handle = families_store().handle_for_index(parent);
    const uint64_t child_handle = families_store().handle_for_index(child);
'''+transfer+'''
    _family_indices_dirty = true;
    _person_indices_dirty = true;
}

bool NativeEconomyRuntime::resolve_family_split_offer(
        const FamilyFoundingOffer &offer, int32_t choice_index) {
    int32_t parent = -1;
    if (!families_store().valid_handle(offer.source_family_handle, parent) ||
        choice_index < 0 || choice_index >= static_cast<int32_t>(offer.candidates.size()) ||
        offer.cell == families_store().origin_cell[parent] ||
        family_population_in_cell(offer.source_family_handle, offer.cell) <= 0) return false;
    const auto &candidate = offer.candidates[static_cast<size_t>(choice_index)];
    if (_family_stable_ids.count(candidate.stable_id) != 0) return false;
    const int32_t child = families_store().allocate();
    reset_family_policy_factors(child);
    const uint64_t child_handle = families_store().handle_for_index(child);
    families_store().stable_id.write_scalar(child, candidate.stable_id, market_mutation_sink());
    _family_stable_ids.insert(candidate.stable_id);
    families_store().surname_id.write_scalar(child, candidate.surname_id, market_mutation_sink());
    families_store().surname_disambiguator.write_scalar(child, 0, market_mutation_sink());
    if (candidate.surname_id >= 0 && static_cast<size_t>(candidate.surname_id) < _family_surname_members.size()) {
        auto &bucket = _family_surname_members[candidate.surname_id];
        for (int32_t index : bucket) {
            if (index >= 0 && index < static_cast<int32_t>(families_store().active.size()) &&
                families_store().active[index] != 0 && index != child)
                families_store().surname_disambiguator.write_scalar(child, std::max(
                    families_store().surname_disambiguator[child],
                    families_store().surname_disambiguator[index] + 1U), market_mutation_sink());
        }
        bucket.push_back(child);
    }
    families_store().founded_day.write_scalar(child, std::max<int64_t>(0, _current_day.get()), market_mutation_sink());
    families_store().home_cell.write_scalar(child, offer.cell, market_mutation_sink());
    families_store().origin_cell.write_scalar(child, offer.cell, market_mutation_sink());
    families_store().origin_ethnicity.write_scalar(child, families_store().origin_ethnicity[parent], market_mutation_sink());
    families_store().culture_group_id.write_scalar(child, candidate.culture_group_id, market_mutation_sink());
    families_store().flags.write_scalar(child, static_cast<uint16_t>(
        families_store().flags[parent] & ~FAMILY_FLAG_STARTER), market_mutation_sink());
    families_store().split_sequence.write_scalar(child, 0, market_mutation_sink());
    families_store().split_sequence.write_scalar(parent, families_store().split_sequence[parent] + 1U, market_mutation_sink());
    transfer_family_branch(parent, child, offer.cell);
    const uint64_t parent_handle = offer.source_family_handle;
    for (size_t t = 0; t < candidate.trait_ids.size(); ++t) {
        uint8_t core = 0;
        for (const auto &roll : family_trait_rolls())
            if (roll.family_handle == parent_handle && roll.trait_id == candidate.trait_ids[t]) core = roll.core;
        family_trait_rolls().push_back({child_handle, candidate.trait_ids[t], candidate.trait_strength_q16[t], core});
    }
    mark_family_behavior_cache_dirty(FAMILY_BEHAVIOR_DIRTY_TRAITS);
    if (candidate.effect_id >= 0) {
        auto it = std::lower_bound(_family_founding_effects.begin(), _family_founding_effects.end(),
            std::make_pair(candidate.stable_id, std::numeric_limits<int32_t>::min()));
        _family_founding_effects.insert(it, {candidate.stable_id, candidate.effect_id});
    }
    auto lineage = std::lower_bound(_family_split_parents.begin(), _family_split_parents.end(),
        std::make_pair(candidate.stable_id, std::numeric_limits<int64_t>::min()));
    _family_split_parents.insert(lineage, {candidate.stable_id, families_store().stable_id[parent]});
    const uint16_t split_flags = families_store().flags[parent];
'''+gifts+'''
    family_trait_rolls().sort([](const FamilyTraitRoll &a, const FamilyTraitRoll &b) {
        return std::tie(a.family_handle, a.trait_id) < std::tie(b.family_handle, b.trait_id);
    });
    ++_families_formed;
    return true;
}

void NativeEconomyRuntime::reunite_split_family_branches() {
    if (_family_split_parents.empty()) return;
    // A settled child owns the whole local branch. Later arrivals from its
    // parent join it instead of spawning another numbered copy of that house.
    for (int32_t child = 0; child < static_cast<int32_t>(families_store().active.size()); ++child) {
        if (families_store().active[child] == 0) continue;
        const int64_t stable = families_store().stable_id[child];
        const auto lineage = std::lower_bound(_family_split_parents.begin(), _family_split_parents.end(),
            std::make_pair(stable, std::numeric_limits<int64_t>::min()));
        if (lineage == _family_split_parents.end() || lineage->first != stable) continue;
        const int32_t cell = families_store().origin_cell[child];
        if (cell < 0 || cell >= _cell_count.get()) continue;
        for (int32_t p = _family_cell_offsets[cell]; p < _family_cell_offsets[cell + 1]; ++p) {
            const int32_t parent = _family_cell_indices[p];
            if (families_store().stable_id[parent] == lineage->second) {
                transfer_family_branch(parent, child, cell);
                break;
            }
        }
    }
}

void NativeEconomyRuntime::split_family_branches() {
    if (_family_runtime_mode.get() != 2 || _family_split_population_threshold.get() <= 0) return;
    reunite_split_family_branches();
    if (_family_indices_dirty) rebuild_family_indices(false);
    struct Candidate { int32_t parent; int32_t cell; int64_t stable; };
    std::vector<Candidate> candidates;
    for (int32_t parent = 0; parent < static_cast<int32_t>(families_store().active.size()); ++parent) {
        if (families_store().active[parent] == 0) continue;
        std::map<int32_t, int64_t> branch_population;
        for (int32_t p = _family_member_offsets[parent]; p < _family_member_offsets[parent + 1]; ++p) {
            const auto &edge = family_memberships()[_family_member_edge_indices[p]];
            int32_t slot = -1;
            if (edge.people > 0 && population_store().valid_handle(edge.cohort_handle, slot))
                branch_population[population_store().page_cell[slot / COHORT_PAGE_SIZE]] += edge.people;
        }
        for (const auto &branch : branch_population)
            if (branch.first != families_store().origin_cell[parent] &&
                branch.second >= _family_split_population_threshold.get())
                candidates.push_back({parent, branch.first, families_store().stable_id[parent]});
    }
    std::sort(candidates.begin(), candidates.end(), [](const Candidate &a, const Candidate &b) {
        return std::tie(a.stable, a.cell) < std::tie(b.stable, b.cell);
    });
    for (const auto &candidate : candidates) {
        if (family_founding_offer_for_cell(candidate.cell) >= 0) continue;
        FamilyFoundingOffer offer;
        if (!build_family_split_offer(candidate.parent, candidate.cell, offer)) continue;
        offer.offer_id = _next_family_founding_offer_id++;
        if (family_founding_player_choice(candidate.cell)) {
            _family_founding_offers.push_back(std::move(offer));
            _family_founding_offer_index_dirty = true;
            ++_family_offers_opened;
        } else if (resolve_family_split_offer(offer, family_founding_auto_choice(offer))) {
            ++_family_offers_auto_resolved;
        }
    }
}
'''
s=s[:a]+new+s[b:]
p.write_text(s,encoding='utf-8')
