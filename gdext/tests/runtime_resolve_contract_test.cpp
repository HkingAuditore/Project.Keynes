#include "runtime_resolve_contract.h"
#include "runtime_switch_registry.h"
#include <vector>
#include <cassert>
#include <cstdlib>
#include <string>
int main() {
    struct Command { uint64_t request_id; int value; };
    std::vector<Command> rows;
    using namespace pk;
    assert(resolve_enqueue<ResolveFlow::CountryCommand>(rows, Command{0,1},2)==ResolveResult::InvalidIdentity);
    assert(rows.empty());
    assert(resolve_enqueue<ResolveFlow::EconomyCommand>(rows, Command{7,2},2)==ResolveResult::Accepted);
    assert(resolve_enqueue<ResolveFlow::TriggerCommand>(rows, Command{8,3},2)==ResolveResult::Accepted);
    assert(resolve_enqueue<ResolveFlow::TriggerCommand>(rows, Command{9,4},2)==ResolveResult::Capacity);
    assert(rows.size()==2 && rows[0].value==2 && rows[1].value==3);
    assert(resolve_find_receipt(rows,7)->value==2 && !resolve_find_receipt(rows,9));
    assert((ResolveOrder{1,9,1,1}<ResolveOrder{2,0,0,0}));
    assert((ResolveOrder{1,2,9,1}<ResolveOrder{1,3,0,0}));
    assert((ResolveOrder{1,2,3,9}<ResolveOrder{1,2,4,0}));
    assert((ResolveOrder{1,2,3,4}<ResolveOrder{1,2,3,5}));
    setenv("PK_SIM_DAY_TRACE","1",1);
    assert(runtime_switch_value(RuntimeSwitch::PK_SIM_DAY_TRACE)==nullptr);
    setenv("PK_SIM_DAY_TRACE","relative/path",1);
    assert(runtime_switch_value(RuntimeSwitch::PK_SIM_DAY_TRACE)==nullptr);
    setenv("PK_SIM_DAY_TRACE","/tmp/keynes-arch-phase1/test.log",1);
    assert(std::string(runtime_switch_value(RuntimeSwitch::PK_SIM_DAY_TRACE))=="/tmp/keynes-arch-phase1/test.log");
}
