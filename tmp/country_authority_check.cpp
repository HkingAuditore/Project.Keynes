#include "../gdext/src/runtime_country_pod.h"

#include <cassert>
#include <iostream>

using namespace pk;

static RuntimeCountryPodSnapshot make_state() {
    RuntimeCountryPodSnapshot s;
    s.generation = 1;
    s.committed_day = -1;
    s.cell_count = 4;
    s.country_count = 2;
    s.technology_words = 1;
    s.technology_count = 4;
    s.good_count = 1;
    s.bootstrapped = true;
    s.research_active_index_valid = true;
    s.country_active = {1, 1};
    s.country_generation = {1, 1};
    s.country_state_version = {0, 0};
    s.research_active_country_slots = {0, 1};
    s.territory_count = {2, 2};
    s.country_cash = {100, 100};
    s.country_goods = {0, 0};
    s.cell_country_slot = {0, 0, 1, 1};
    s.territory_offsets = {0, 2, 4};
    s.territory_cells = {0, 1, 2, 3};
    s.country_technologies = {0, 0};
    s.country_discovered = {15, 15};
    s.country_pending_technologies = {0, 0};
    s.research_queues.assign(2 * 4 * 8, -1);
    s.research_queue_lengths.assign(2 * 4, 0);
    s.research_weights_bp.assign(2 * 4, 2500);
    s.research_auto_purchase = {1, 1};
    s.research_daily_budgets = {100, 100};
    s.research_deferred_points = {0, 0};
    s.research_progress.assign(2 * 4, 0);
    s.research_purchased_total = {0, 0};
    s.research_consumed_total = {0, 0};
    s.research_progress_total = {0, 0};
    s.research_completed_total = {0, 0};
    s.is_water = {0, 0, 0, 0};
    s.catalog_hash = 99;
    return s;
}

static RuntimeCountryPodCatalog make_catalog() {
    RuntimeCountryPodCatalog c;
    c.catalog_hash = 99;
    c.technology_count = 4;
    c.technology_words = 1;
    c.technology_points_good_id = 0;
    c.technology_costs = {1, 1, 1, 1};
    c.technology_domains = {0, 1, 2, 3};
    c.technology_flags = {0, 0, 0, 0};
    c.prerequisite_offsets = {0, 0, 0, 0, 0};
    c.entry_milestone_indices = {-1, -1, -1, -1};
    c.research_condition_offsets = {0, 0, 0, 0, 0};
    c.research_conditions_complete = true;
    return c;
}

static RuntimeCountryCommand command(uint16_t opcode, uint64_t request,
                                     uint32_t producer, uint64_t sequence,
                                     uint64_t handle, int32_t cell = -1) {
    RuntimeCountryCommand c;
    c.opcode = opcode;
    c.request_id = request;
    c.producer_id = producer;
    c.sequence = sequence;
    c.requested_day = 0;
    c.effective_day = 0;
    c.target_handle = handle;
    c.cell = cell;
    c.domain = -1;
    c.position = -1;
    return c;
}

int main() {
    std::string self_error;
    assert(RuntimeCountryPodAuthority::self_test(self_error));
    RuntimeCountryPodSnapshot state = make_state();
    RuntimeCountryPodCatalog catalog = make_catalog();
    RuntimeCountryPodAuthority authority;
    std::string error;
    assert(authority.bootstrap(state, catalog, error));

    RuntimeCountryCommand grant = command(4, 1, 2, 1,
        (uint64_t{1} << 32u) | 1u);
    grant.aux = 0;
    assert(authority.queue_command(grant, error));
    RuntimeCountryPodPlan plan;
    assert(authority.plan_day(0, 1, plan, error));
    assert(!authority.commit_day(plan, {}, error));
    RuntimeCountryPodSnapshot unchanged;
    assert(authority.snapshot(unchanged, error));
    assert(unchanged.committed_day == -1 && unchanged.country_pending_technologies[1] == 0);

    RuntimeDomainAck ack;
    ack.request_id = grant.request_id;
    ack.target_handle = grant.target_handle;
    ack.target_generation = 1;
    ack.domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
    assert(authority.commit_day(plan, {ack}, error));
    RuntimeCountryCommand transfer = command(3, 2, 2, 2,
        (uint64_t{1} << 32u) | 1u, 0);
    transfer.requested_day = 1;
    transfer.effective_day = 1;
    assert(authority.queue_command(transfer, error));
    assert(authority.plan_day(1, 2, plan, error));
    assert(authority.commit_day(plan, {}, error));
    RuntimeCountryPodSnapshot committed;
    assert(authority.snapshot(committed, error));
    assert(committed.committed_day == 1 && committed.cell_country_slot[0] == 1);
    assert(committed.territory_offsets == std::vector<int32_t>({0, 1, 4}));

    RuntimeCountryPodSaveSection section;
    assert(authority.encode_save(section, error));
    RuntimeCountryPodAuthority restored;
    assert(restored.restore_save(section, catalog, error));
    assert(restored.state_hash() == authority.state_hash());
    section.payload.back() ^= 1u;
    assert(!restored.restore_save(section, catalog, error));
    assert(restored.state_hash() == authority.state_hash());
    std::cout << "country authority checks passed\n";
}
