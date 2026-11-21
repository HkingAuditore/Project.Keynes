#include "native_simulation_host.h"
#include "runtime_era_reward.h"
#include <algorithm>
#include <cassert>

namespace pk {
bool NativeSimulationHost::configure_annual_development(uint64_t handle,int64_t length,
        int64_t day,const AnnualDevelopmentProfile &profile,const AnnualEconomyFacts &baseline,
        const AnnualCountryFacts &country,std::string &error){
    std::lock_guard<std::mutex> lock(_annual_mutex);
    if(_annual_ledger.configured()){
        if(_annual_ledger.country_handle()!=handle||_annual_ledger.days_per_year()!=length){error="annual_session_identity_changed";return false;}
        if (!_annual_ledger.update_profile(profile,error)) return false;
        publish_annual_view_locked();
        return true;
    }
    if(!_annual_ledger.configure(handle,length,day,profile,error))return false;
    _annual_ledger.seed(baseline,country);_annual_ledger.commit_day(day,country,0);_annual_queued_reward=0;
    publish_annual_view_locked();
    _annual_country.store(handle,std::memory_order_release);
    _annual_enabled.store(true,std::memory_order_release);return true;
}
void NativeSimulationHost::publish_annual_economy(const AnnualEconomyFacts &facts){
    if(!annual_development_enabled())return;
    std::lock_guard<std::mutex> lock(_annual_mutex);_annual_ledger.observe_economy(facts);
}
void NativeSimulationHost::commit_annual_day(int64_t day,const AnnualCountryFacts &country,uint64_t draws){
    if(!annual_development_enabled())return;
    std::lock_guard<std::mutex> lock(_annual_mutex);
    _annual_ledger.commit_day(day,country,draws);
    publish_annual_view_locked();
}
void NativeSimulationHost::commit_annual_worker_day(int64_t day){
    if(!annual_development_enabled()||!domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)||!domain_is_worker_authoritative(RuntimeDomainId::IDEOLOGY))return;
    const auto country_view = copy_annual_country_view();
    assert(!country_view.data || country_view.observe(_annual_country_view_version));
    const auto country = country_view.data;
    const auto ideology_view = copy_annual_ideology_view();
    assert(!ideology_view.data || ideology_view.observe(_annual_ideology_view_version));
    const auto ideology = ideology_view.data;
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
        if (receipt.status == RuntimeIdeologyPodReceiptStatus::SETTLED) {
            const auto before = _annual_ledger.revision();
            _annual_ledger.settle_reward(receipt.sequence);
            _annual_history_changed |= before != _annual_ledger.revision();
        }
        // A rejected internal grant is visible as pending, never as paid.
    }
}
bool NativeSimulationHost::annual_pending_reward(AnnualDevelopmentReport &out) const{
    std::lock_guard<std::mutex> lock(_annual_mutex);for(const auto &r:_annual_ledger.reports())if(!r.reward_settled){out=r;return true;}return false;
}
void NativeSimulationHost::settle_annual_reward(uint64_t sequence) {
    std::lock_guard<std::mutex> lock(_annual_mutex);
    _annual_history_changed |= _annual_ledger.settle_reward(sequence);
    publish_annual_view_locked();
}
void NativeSimulationHost::annual_status(uint64_t &revision,int64_t &day,uint64_t &ready,bool &pending,size_t &count) const{
    const auto view = std::atomic_load(&_published_annual);
    revision = view ? view->revision : 0;
    day = view ? view->day : -1;
    ready = view ? view->ready : 0;
    pending = view && view->reward_pending;
    count = view ? view->history->size() : 0;
}
bool NativeSimulationHost::annual_report(uint64_t id,AnnualDevelopmentReport &out) const{
    const auto view = std::atomic_load(&_published_annual);
    if (view) for (const auto &report : *view->history) if (report.id == id) {
        out = report;
        return true;
    }
    return false;
}
std::vector<AnnualDevelopmentReport> NativeSimulationHost::annual_history(uint32_t offset,uint32_t limit) const{
    const auto view = std::atomic_load(&_published_annual);
    std::vector<AnnualDevelopmentReport> result;
    if (!view) return result;
    const auto &rows = *view->history;
    limit = std::min<uint32_t>(limit, 64);
    for (size_t i = offset; i < rows.size() && result.size() < limit; ++i)
        result.push_back(rows[rows.size() - 1 - i]);
    return result;
}
const char *NativeSimulationHost::mark_annual_presented(uint64_t id) {
    if (!annual_development_enabled()) return "annual_unconfigured";
    AnnualDevelopmentReport report;
    if (!annual_report(id, report)) return "annual_report_not_found";
    if (!report.reward_settled) return "annual_report_reward_pending";
    if (report.presented) return nullptr;
    if (!annual_worker_managed()) {
        std::lock_guard<std::mutex> lock(_annual_mutex);
        if (!_annual_ledger.mark_presented(id)) return "annual_report_not_found";
        _annual_history_changed = true;
        publish_annual_view_locked();
        return nullptr;
    }
    {
        int64_t day = 0;
        auto admission = admit_command(day);
        if (!admission.accepted() || _stop_requested.load(std::memory_order_acquire) ||
                state() == RuntimeWorkerState::STOPPED || state() == RuntimeWorkerState::FAULTED)
            return "annual_executor_unavailable";
        std::lock_guard<std::mutex> control(_control_mutex);
        if (std::find(_annual_presentations.begin(), _annual_presentations.end(), id) ==
                _annual_presentations.end()) _annual_presentations.push_back(id);
    }
    if (inline_daily_mode()) service_annual_presentations();
    else _control_cv.notify_one();
    return nullptr;
}

bool NativeSimulationHost::service_annual_presentations() {
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        if (_annual_presentations.empty()) return false;
    }
    std::lock_guard<std::mutex> boundary(_economy_authority_boundary_mutex);
    std::deque<uint64_t> requests;
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        requests.swap(_annual_presentations);
    }
    std::lock_guard<std::mutex> lock(_annual_mutex);
    for (const auto id : requests) _annual_history_changed |= _annual_ledger.mark_presented(id);
    publish_annual_view_locked();
    return true;
}

std::vector<uint8_t> NativeSimulationHost::encode_annual_save() const{std::lock_guard<std::mutex> lock(_annual_mutex);std::vector<uint8_t> bytes;if(_annual_ledger.configured())_annual_ledger.encode(bytes);return bytes;}
bool NativeSimulationHost::restore_annual_save(const uint8_t *bytes,size_t size,std::string &error){
    std::lock_guard<std::mutex> lock(_annual_mutex);if(!_annual_ledger.restore(bytes,size,error))return false;
    _annual_history_changed = true;
    publish_annual_view_locked();
    _annual_country.store(_annual_ledger.country_handle(),std::memory_order_release);_annual_enabled.store(true,std::memory_order_release);_annual_queued_reward=0;return true;
}
void NativeSimulationHost::publish_annual_view_locked() {
    const auto previous = std::atomic_load(&_published_annual);
    auto view = std::make_shared<AnnualReportPublication>();
    view->revision = _annual_ledger.revision();
    view->day = _annual_ledger.last_day();
    view->ready = _annual_ledger.ready_report_id();
    view->reward_pending = _annual_ledger.has_pending_reward();
    const auto &reports = _annual_ledger.reports();
    view->history = !previous || _annual_history_changed || previous->history->size() != reports.size()
        ? std::make_shared<const std::vector<AnnualDevelopmentReport>>(reports)
        : previous->history;
    _annual_history_changed = false;
    std::atomic_store(&_published_annual, std::shared_ptr<const AnnualReportPublication>(std::move(view)));
}
} // namespace pk
