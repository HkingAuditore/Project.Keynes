struct TechView {
    const RuntimeCountryPodSnapshot &state;
    const RuntimeCountryPodCatalog &catalog;
    int32_t slot;
    size_t base;
    std::vector<uint64_t> queued;

    TechView(const RuntimeCountryPodSnapshot &s, const RuntimeCountryPodCatalog &c,
             int32_t country_slot)
        : state(s), catalog(c), slot(country_slot),
          base(static_cast<size_t>(country_slot) * c.technology_words),
          queued(c.technology_words, 0) {
        const size_t country_base = static_cast<size_t>(slot) * COUNTRY_AI_DOMAIN_COUNT;
        for (uint32_t domain = 0; domain < COUNTRY_AI_DOMAIN_COUNT; ++domain) {
            const size_t length_index = country_base + domain;
            if (length_index >= state.research_queue_lengths.size()) continue;
            const size_t queue_base = length_index * COUNTRY_AI_QUEUE_SLOTS;
            for (uint32_t i = 0; i < state.research_queue_lengths[length_index]; ++i) {
                const int32_t tech = state.research_queues[queue_base + i];
                if (tech >= 0 && tech < static_cast<int32_t>(c.technology_count))
                    queued[static_cast<size_t>(tech / 64)] |= uint64_t{1} << (tech % 64);
            }
        }
    }
    static bool test(const std::vector<uint64_t> &bits, size_t base, int32_t tech) {
        const size_t word = base + static_cast<size_t>(tech / 64);
        return word < bits.size() && ((bits[word] >> (tech % 64)) & 1u) != 0;
    }
    bool done(int32_t tech) const { return test(state.country_technologies, base, tech); }
    bool discovered(int32_t tech) const { return test(state.country_discovered, base, tech); }
    bool pending(int32_t tech) const {
        return test(state.country_pending_technologies, base, tech);
    }
    bool is_queued(int32_t tech) const { return test(queued, 0, tech); }
    void mark_queued(int32_t tech) {
        queued[static_cast<size_t>(tech / 64)] |= uint64_t{1} << (tech % 64);
    }
    bool available(int32_t tech) const {
        return discovered(tech) && !done(tech) && !pending(tech) && !is_queued(tech) &&
               country_core_research_condition_met(state, catalog, slot, tech);
    }
    int64_t remaining_closure_cost(const CountryAiTechIndex &index, int32_t tech) const {
        int64_t total = 0;
        const size_t closure_base = static_cast<size_t>(tech) * index.words;
        for (uint32_t w = 0; w < index.words; ++w) {
            uint64_t bits = index.closure[closure_base + w] &
                            ~state.country_technologies[base + w];
            while (bits != 0) {
                const int bit = ctz64(bits);
                bits &= bits - 1;
                const int32_t id = static_cast<int32_t>(w * 64u + static_cast<uint32_t>(bit));
                if (id < static_cast<int32_t>(catalog.technology_count))
                    total += std::max<int64_t>(0, catalog.technology_costs[static_cast<size_t>(id)]);
            }
        }
        return total;
    }
};

struct MilestoneStatus {
    int32_t goal = -1;
    int32_t gap = 0;
    int32_t completed = 0;
};

MilestoneStatus milestone_status(const TechView &view, const CountryAiTechIndex &index) {
    MilestoneStatus status;
    const RuntimeCountryPodCatalog &catalog = view.catalog;
    for (const int32_t milestone : index.milestones) {
        if (view.done(milestone)) { ++status.completed; continue; }
        if (view.pending(milestone)) continue;
        const int32_t entry = static_cast<size_t>(milestone) < catalog.entry_milestone_indices.size()
            ? catalog.entry_milestone_indices[static_cast<size_t>(milestone)] : -1;
        if (entry >= 0 && !view.done(entry)) continue;
        int32_t have = 0;
        const int32_t begin = catalog.milestone_offsets[static_cast<size_t>(milestone)];
        const int32_t end = catalog.milestone_offsets[static_cast<size_t>(milestone + 1)];
        for (int32_t edge = begin; edge < end; ++edge)
            if (view.done(catalog.milestone_candidates[static_cast<size_t>(edge)])) ++have;
        const int32_t required = catalog.milestone_required_counts[static_cast<size_t>(milestone)];
        const int32_t gap = std::max(0, required - have);
        if (status.goal < 0 || gap < status.gap) {
            status.goal = milestone;
            status.gap = gap;
        }
    }
    return status;
}

int32_t count_frontier(const RuntimeCountryPodSnapshot &state, int32_t slot,
                       const std::vector<int32_t> *neighbors, std::vector<int32_t> &scratch) {
    scratch.clear();
    if (neighbors == nullptr || state.territory_offsets.size() != state.country_count + 1u)
        return 0;
    const int32_t begin = state.territory_offsets[static_cast<size_t>(slot)];
    const int32_t end = state.territory_offsets[static_cast<size_t>(slot) + 1u];
    const int32_t cell_count = static_cast<int32_t>(state.cell_country_slot.size());
    for (int32_t i = begin; i < end; ++i) {
        const int32_t cell = state.territory_cells[static_cast<size_t>(i)];
        for (int32_t k = 0; k < 6; ++k) {
            const size_t ni = static_cast<size_t>(cell) * 6u + static_cast<size_t>(k);
            if (ni >= neighbors->size()) break;
            const int32_t n = (*neighbors)[ni];
            if (n < 0 || n >= cell_count) continue;
            if (state.cell_country_slot[static_cast<size_t>(n)] >= 0) continue;
            if (static_cast<size_t>(n) < state.is_water.size() &&
                state.is_water[static_cast<size_t>(n)] != 0) continue;
            scratch.push_back(n);
        }
    }
    std::sort(scratch.begin(), scratch.end());
    scratch.erase(std::unique(scratch.begin(), scratch.end()), scratch.end());
    return static_cast<int32_t>(scratch.size());
}
