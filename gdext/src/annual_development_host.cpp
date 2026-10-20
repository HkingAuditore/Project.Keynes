#include "native_simulation_host.h"
#include <algorithm>

namespace pk {
bool NativeSimulationHost::configure_annual_development(uint64_t handle,int64_t length,
        int64_t day,const AnnualDevelopmentProfile &profile,const AnnualEconomyFacts &baseline,
        const AnnualCountryFacts &country,std::string &error){
    std::lock_guard<std::mutex> lock(_annual_mutex);
    if(_annual_ledger.configured()){
        if(_annual_ledger.country_handle()!=handle||_annual_ledger.days_per_year()!=length){error="annual_session_identity_changed";return false;}
        return true;
    }
    if(!_annual_ledger.configure(handle,length,day,profile,error))return false;
    _annual_ledger.seed(baseline,country);_annual_ledger.commit_day(day,country,0);_annual_queued_reward=0;
    _annual_country.store(handle,std::memory_order_release);
    _annual_enabled.store(true,std::memory_order_release);return true;
}
void NativeSimulationHost::publish_annual_economy(const AnnualEconomyFacts &facts){
    if(!annual_development_enabled())return;
    std::lock_guard<std::mutex> lock(_annual_mutex);_annual_ledger.observe_economy(facts);
}
void NativeSimulationHost::commit_annual_day(int64_t day,const AnnualCountryFacts &country,uint64_t draws){
    if(!annual_development_enabled())return;
    std::lock_guard<std::mutex> lock(_annual_mutex);_annual_ledger.commit_day(day,country,draws);
}
void NativeSimulationHost::commit_annual_worker_day(int64_t day){
    if(!annual_development_enabled()||!domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)||!domain_is_worker_authoritative(RuntimeDomainId::IDEOLOGY))return;
    const auto country=country_asset_snapshot();const auto ideology=ideology_pod_snapshot();
    if(!country)return;
    const uint64_t handle=annual_country_handle();const uint32_t slot=static_cast<uint32_t>(handle);
    if(slot>=country->country_count||slot>=country->country_generation.size()||country->country_generation[slot]!=static_cast<uint32_t>(handle>>32u))return;
    uint64_t draws=0;
    if(ideology)for(const auto &row:ideology->countries)if(row.handle==handle){draws=row.draw_sequence;break;}
    AnnualCountryFacts f;f.handle=handle;
    if(slot<country->country_display_names.size())f.name=country->country_display_names[slot];
    if(slot<country->country_cash.size())f.treasury=country->country_cash[slot];
    if(slot<country->territory_count.size())f.territory=country->territory_count[slot];
    if(slot<country->research_purchased_total.size())f.research_purchased=country->research_purchased_total[slot];
    if(slot<country->research_consumed_total.size())f.research_consumed=country->research_consumed_total[slot];
    for(uint32_t tech=0;tech<country->technology_count;++tech){const size_t at=static_cast<size_t>(slot)*country->technology_words+tech/64u;if(at<country->country_technologies.size()&&(country->country_technologies[at]&(1ull<<(tech%64u))))f.technologies.push_back(static_cast<int32_t>(tech));}
    commit_annual_day(day,f,draws);
}
void NativeSimulationHost::queue_annual_worker_reward(int64_t day){
    AnnualDevelopmentReport pending;
    {
        std::lock_guard<std::mutex> lock(_annual_mutex);
        auto *r=_annual_ledger.pending_reward();if(!r||r->reward_sequence==_annual_queued_reward)return;
        pending=*r;_annual_queued_reward=r->reward_sequence;
    }
    RuntimeIdeologyPodCommand cmd;cmd.opcode=RuntimeIdeologyPodOpcode::GRANT_POINTS;
    cmd.country_handle=pending.country_handle;cmd.producer_id=ANNUAL_REWARD_PRODUCER;
    cmd.sequence=pending.reward_sequence;cmd.request_id=0x4152000000000000ull|pending.id;
    cmd.effective_day=day;cmd.requested_day=day;cmd.value_q16=pending.reward_q16;
    // The reward precedes player commands on this day. Its value was frozen at
    // last year's commit, before any new-year draw can change the price.
    cmd.source_priority=-100;
    std::string error;
    if(!queue_ideology_pod_command(cmd,error)){
        std::lock_guard<std::mutex> lock(_annual_mutex);_annual_queued_reward=0;
    }
}
void NativeSimulationHost::settle_annual_worker_reward(const RuntimeIdeologyPodSnapshot &snapshot){
    if(!annual_development_enabled())return;
    std::lock_guard<std::mutex> lock(_annual_mutex);
    for(const auto &receipt:snapshot.receipts)if(receipt.producer_id==ANNUAL_REWARD_PRODUCER){
        if(receipt.status==RuntimeIdeologyPodReceiptStatus::SETTLED)_annual_ledger.settle_reward(receipt.sequence);
        // A rejected internal grant is visible as pending, never as paid.
    }
}
bool NativeSimulationHost::annual_pending_reward(AnnualDevelopmentReport &out) const{
    std::lock_guard<std::mutex> lock(_annual_mutex);for(const auto &r:_annual_ledger.reports())if(!r.reward_settled){out=r;return true;}return false;
}
void NativeSimulationHost::settle_annual_reward(uint64_t sequence){std::lock_guard<std::mutex> lock(_annual_mutex);_annual_ledger.settle_reward(sequence);}
void NativeSimulationHost::annual_status(uint64_t &revision,int64_t &day,uint64_t &ready,bool &pending,size_t &count) const{
    std::lock_guard<std::mutex> lock(_annual_mutex);revision=_annual_ledger.revision();day=_annual_ledger.last_day();ready=0;pending=false;count=_annual_ledger.reports().size();
    ready=_annual_ledger.ready_report_id();pending=_annual_ledger.has_pending_reward();
}
bool NativeSimulationHost::annual_report(uint64_t id,AnnualDevelopmentReport &out) const{
    std::lock_guard<std::mutex> lock(_annual_mutex);for(const auto &r:_annual_ledger.reports())if(r.id==id){out=r;return true;}return false;
}
std::vector<AnnualDevelopmentReport> NativeSimulationHost::annual_history(uint32_t offset,uint32_t limit) const{
    std::lock_guard<std::mutex> lock(_annual_mutex);std::vector<AnnualDevelopmentReport> result;const auto &rows=_annual_ledger.reports();limit=std::min<uint32_t>(limit,64);
    for(size_t i=offset;i<rows.size()&&result.size()<limit;++i)result.push_back(rows[rows.size()-1-i]);return result;
}
bool NativeSimulationHost::mark_annual_presented(uint64_t id){std::lock_guard<std::mutex> lock(_annual_mutex);return _annual_ledger.mark_presented(id);}
std::vector<uint8_t> NativeSimulationHost::encode_annual_save() const{std::lock_guard<std::mutex> lock(_annual_mutex);std::vector<uint8_t> bytes;if(_annual_ledger.configured())_annual_ledger.encode(bytes);return bytes;}
bool NativeSimulationHost::restore_annual_save(const uint8_t *bytes,size_t size,std::string &error){
    std::lock_guard<std::mutex> lock(_annual_mutex);if(!_annual_ledger.restore(bytes,size,error))return false;
    _annual_country.store(_annual_ledger.country_handle(),std::memory_order_release);_annual_enabled.store(true,std::memory_order_release);_annual_queued_reward=0;return true;
}
} // namespace pk
