from pathlib import Path
p=Path('gdext/src/economy_runtime.cpp')
s=p.read_text(encoding='utf-8')
a=s.index('void NativeEconomyRuntime::transfer_family_branch(')
b=s.index('\nbool NativeEconomyRuntime::resolve_family_split_offer(',a)
s=s[:a]+'''void NativeEconomyRuntime::transfer_family_branch(int32_t parent, int32_t child, int32_t cell) {
    const uint64_t parent_handle = families_store().handle_for_index(parent);
    const uint64_t child_handle = families_store().handle_for_index(child);
    // Transfers only rewrite existing rows; the CSR row positions remain valid
    // until the structural rebuild, including several splits in one commit.
    for (int32_t p = _family_member_offsets[parent]; p < _family_member_offsets[parent + 1]; ++p) {
        auto edge_write = family_memberships().edit_row(_family_member_edge_indices[p], market_mutation_sink());
        auto &edge = edge_write[0];
        int32_t slot = -1;
        if (edge.family_handle == parent_handle && edge.people > 0 &&
            population_store().valid_handle(edge.cohort_handle, slot) &&
            population_store().page_cell[slot / COHORT_PAGE_SIZE] == cell)
            edge.family_handle = child_handle;
    }
    for (int32_t p = _family_owned_offsets[parent]; p < _family_owned_offsets[parent + 1]; ++p) {
        auto ownership_write = family_ownerships().edit_row(_family_owned_edge_indices[p], market_mutation_sink());
        auto &ownership = ownership_write[0];
        const int32_t group = building_index_for_handle(ownership.building_handle);
        if (ownership.family_handle == parent_handle && ownership.owned_count > 0 &&
            group >= 0 && buildings_store().cell[group] == cell)
            ownership.family_handle = child_handle;
    }
    const bool person_csr = static_cast<size_t>(parent + 1) < _person_family_offsets.size();
    const int32_t begin = person_csr ? _person_family_offsets[parent] : 0;
    const int32_t end = person_csr ? _person_family_offsets[parent + 1]
        : static_cast<int32_t>(persons_store().active.size());
    for (int32_t p = begin; p < end; ++p) {
        const int32_t person = person_csr ? _person_family_indices[p] : p;
        if (persons_store().active[person] == 0 || persons_store().family_handle[person] != parent_handle) continue;
        int32_t slot = -1;
        bool move = population_store().valid_handle(persons_store().cohort_handle[person], slot) &&
            population_store().page_cell[slot / COHORT_PAGE_SIZE] == cell;
        const int32_t group = building_index_for_handle(persons_store().building_handle[person]);
        if (!move && group >= 0 && buildings_store().cell[group] == cell) move = true;
        if (move) persons_store().family_handle.write_scalar(person, child_handle, market_mutation_sink());
    }
    _family_indices_dirty = true;
    _person_indices_dirty = true;
}
''' + s[b:]
# Normalize indentation of the extracted split-gift block only.
a=s.index('    const uint16_t split_flags = families_store().flags[parent];',s.index('bool NativeEconomyRuntime::resolve_family_split_offer('))
b=s.index('\n    family_trait_rolls().sort',a)
part=s[a:b].splitlines()
part=[line[4:] if i>0 and line.startswith('    ') else line for i,line in enumerate(part)]
s=s[:a]+'\n'.join(part)+s[b:]
p.write_text(s,encoding='utf-8')
