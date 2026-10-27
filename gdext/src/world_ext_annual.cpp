#include "world_ext.h"
#include "native_simulation_host.h"
#include "economy_runtime.h"
#include "country_runtime.h"
#include "ideology_runtime.h"
#include <algorithm>

namespace pk {
using namespace godot;
namespace {
Dictionary result(bool ok,const std::string &reason="") {Dictionary d;d["ok"]=ok;d["reason"]=String(reason.c_str());return d;}
template<class T> PackedInt64Array pack(const T &values){PackedInt64Array a;for(auto v:values)a.append(static_cast<int64_t>(v));return a;}
Dictionary metrics(const std::array<int64_t,ANNUAL_METRIC_COUNT> &values){Dictionary d;for(size_t i=0;i<values.size();++i)d[String(annual_metric_key(i))]=values[i];return d;}
Array breakdown(const std::vector<AnnualBreakdown> &rows){Array a;for(const auto&r:rows){Dictionary d;d["id"]=r.id;d["count"]=r.count;d["value"]=r.value;d["secondary"]=r.secondary;a.append(d);}return a;}
Dictionary facts(const AnnualEconomyFacts &f){Dictionary d=metrics(f.values);d["tiers"]=pack(f.tiers);d["satisfaction_dimensions"]=pack(f.satisfaction_dimensions);d["industries"]=breakdown(f.industries);d["professions"]=breakdown(f.professions);d["goods"]=breakdown(f.goods);d["resources"]=breakdown(f.resources);Array towns;for(const auto&t:f.settlements){Dictionary a;a["cell"]=t.cell;a["tier"]=t.tier;a["population"]=t.population;a["buildings"]=t.buildings;a["gdp"]=t.gdp;towns.append(a);}d["towns"]=towns;return d;}
Dictionary report(const AnnualDevelopmentReport &r,bool full){
    Dictionary d;d["ok"]=true;d["id"]=static_cast<int64_t>(r.id);d["country_handle"]=static_cast<int64_t>(r.country_handle);
    d["year"]=r.year;d["country_name"]=String::utf8(r.country_name.c_str());d["era"]=r.era;
    d["score_bp"]=r.score_bp;d["grade_index"]=r.grade;d["grade"]=r.complete?String(std::array<const char*,7>{{"SS","S","A","B","C","D","E"}}[r.grade]):String("—");
    d["complete"]=static_cast<bool>(r.complete);d["reward_q16"]=r.reward_q16;d["reward_settled"]=static_cast<bool>(r.reward_settled);d["presented"]=static_cast<bool>(r.presented);
    d["start_day"]=r.start_day;d["end_day"]=r.end_day;d["scoring_version"]=static_cast<int64_t>(r.scoring_version);
    if(full){d["opening"]=facts(r.opening);d["closing"]=facts(r.closing);d["totals"]=metrics(r.totals);d["quality_average"]=pack(r.quality_average);d["score_parts"]=pack(r.score_parts);d["grade_cap"]=r.cap;d["monthly_gdp"]=pack(r.monthly_gdp);d["monthly_population"]=pack(r.monthly_population);d["new_technologies"]=pack(r.new_technologies);d["industry_totals"]=breakdown(r.industry_totals);d["resource_totals"]=breakdown(r.resource_totals);d["first_gdp"]=r.first_gdp;d["last_gdp"]=r.last_gdp;d["first_days"]=r.first_days;d["last_days"]=r.last_days;}
    return d;
}
AnnualCountryFacts project(const RuntimeCountryPodSnapshot &s,uint64_t handle){
    AnnualCountryFacts f;f.handle=handle;const uint32_t slot=static_cast<uint32_t>(handle);
    if(slot>=s.country_count||slot>=s.country_generation.size()||s.country_generation[slot]!=static_cast<uint32_t>(handle>>32u)){f.handle=0;return f;}
    if(slot<s.country_display_names.size())f.name=s.country_display_names[slot];
    if(slot<s.country_cash.size())f.treasury=s.country_cash[slot];if(slot<s.territory_count.size())f.territory=s.territory_count[slot];
    if(slot<s.research_purchased_total.size())f.research_purchased=s.research_purchased_total[slot];if(slot<s.research_consumed_total.size())f.research_consumed=s.research_consumed_total[slot];
    for(uint32_t tech=0;tech<s.technology_count;++tech){const size_t at=static_cast<size_t>(slot)*s.technology_words+tech/64u;if(at<s.country_technologies.size()&&(s.country_technologies[at]&(1ull<<(tech%64u))))f.technologies.push_back(static_cast<int32_t>(tech));}return f;
}
template<class T,size_t N> bool read_array(const Dictionary &d,const char *key,std::array<T,N> &out){if(!d.has(key))return true;PackedInt32Array a=d[key];if(a.size()!=N)return false;for(size_t i=0;i<N;++i)out[i]=a[static_cast<int64_t>(i)];return true;}
}
Dictionary DCWorldExt::configure_annual_reports(int64_t handle,int64_t length,int64_t initial,const Dictionary &source){
    if(!_country_runtime||!_economy_runtime||!_ideology_runtime)return result(false,"annual_domains_unavailable");
    if(!_runtime_host)_runtime_host=std::make_unique<NativeSimulationHost>();
    auto *economy=static_cast<NativeEconomyRuntime*>(_economy_runtime);economy->attach_simulation_host(_runtime_host.get());
    AnnualDevelopmentProfile p;p.version=static_cast<uint32_t>(static_cast<int64_t>(source.get("version",2)));
    if(!read_array(source,"grade_thresholds",p.grade_thresholds)||!read_array(source,"reward_draws",p.reward_draws)||!read_array(source,"quality_weights",p.quality_weights)||!read_array(source,"quality_targets",p.quality_targets)||!read_array(source,"progress_weights",p.progress_weights)||!read_array(source,"progress_targets",p.progress_targets))return result(false,"annual_profile_shape_invalid");
    p.active_target=source.get("active_target",p.active_target);p.offer_cost=source.get("offer_cost_q16",p.offer_cost);p.max_offer_cost=source.get("offer_cost_max_q16",p.max_offer_cost);p.offer_growth_percent=source.get("offer_cost_growth_percent",p.offer_growth_percent);
    const PackedInt32Array equivalents=source.get("technology_equivalents_q16",PackedInt32Array());for(auto value:equivalents)p.technology_equivalents_q16.push_back(value);
    const PackedInt32Array eras=source.get("technology_eras",PackedInt32Array());for(auto value:eras)p.technology_eras.push_back(value);
    const PackedInt32Array milestones=source.get("era_milestones",PackedInt32Array());for(auto value:milestones)p.era_milestones.push_back(value);
    RuntimeCountryPodSnapshot country;std::string error;
    if(!country_query_runtime()->export_pod_snapshot(country,error))return result(false,error);
    const auto c=project(country,static_cast<uint64_t>(handle));if(c.handle==0)return result(false,"annual_country_invalid");
    return result(_runtime_host->configure_annual_development(static_cast<uint64_t>(handle),length,initial,p,economy->capture_annual_facts(handle,false),c,error),error);
}
Dictionary DCWorldExt::commit_annual_reports(int64_t day){
    if(!_runtime_host||!_runtime_host->annual_development_enabled())return result(false,"annual_unconfigured");
    if(_runtime_host->annual_worker_managed())return get_annual_report_status();
    if(!_economy_runtime||static_cast<NativeEconomyRuntime*>(_economy_runtime)->epoch_active())return result(false,"annual_economy_pending");
    if(!_country_runtime||!static_cast<NativeCountryRuntime*>(_country_runtime)->annual_snapshot_ready())return result(false,"annual_country_day_pending");
    RuntimeCountryPodSnapshot country;std::string error;
    if(!country_query_runtime()->export_pod_snapshot(country,error))return result(false,error);
    auto *ideology=static_cast<NativeIdeologyRuntime*>(_ideology_runtime);
    const auto handle=_runtime_host->annual_country_handle();
    _runtime_host->commit_annual_day(day,project(country,handle),ideology->annual_draw_sequence(handle));
    return get_annual_report_status();
}
Dictionary DCWorldExt::get_annual_report_status() const{
    Dictionary d=result(_runtime_host&&_runtime_host->annual_development_enabled());
    if(!bool(d["ok"]))return d;
    uint64_t revision=0,ready=0;int64_t day=-1;bool pending=false;size_t count=0;
    _runtime_host->annual_status(revision,day,ready,pending,count);d["revision"]=static_cast<int64_t>(revision);d["last_day"]=day;d["ready_report_id"]=static_cast<int64_t>(ready);d["reward_pending"]=pending;d["report_count"]=static_cast<int64_t>(count);d["worker_managed"]=_runtime_host->annual_worker_managed();return d;
}
Dictionary DCWorldExt::get_annual_report_snapshot(int64_t id) const{
    AnnualDevelopmentReport r;return _runtime_host&&id>0&&_runtime_host->annual_report(static_cast<uint64_t>(id),r)?report(r,true):result(false,"annual_report_not_found");
}
Dictionary DCWorldExt::get_annual_report_history(int32_t offset,int32_t limit) const{
    if(!_runtime_host)return result(false,"annual_unconfigured");Dictionary d=result(true);Array rows;
    for(const auto&r:_runtime_host->annual_history(static_cast<uint32_t>(std::max(0,offset)),static_cast<uint32_t>(std::clamp(limit,1,64))))rows.append(report(r,false));
    d["reports"]=rows;return d;
}
Dictionary DCWorldExt::mark_annual_report_presented(int64_t id){return result(_runtime_host&&id>0&&_runtime_host->mark_annual_presented(static_cast<uint64_t>(id)));}
PackedByteArray DCWorldExt::capture_annual_report_state() const{
    PackedByteArray out;if(!_runtime_host)return out;const auto bytes=_runtime_host->encode_annual_save();out.resize(static_cast<int64_t>(bytes.size()));if(!bytes.empty())std::copy(bytes.begin(),bytes.end(),out.ptrw());return out;
}
Dictionary DCWorldExt::restore_annual_report_state(const PackedByteArray &bytes){
    if(bytes.is_empty())return result(true);if(!_runtime_host)_runtime_host=std::make_unique<NativeSimulationHost>();
    std::string error;return result(_runtime_host->restore_annual_save(bytes.ptr(),static_cast<size_t>(bytes.size()),error),error);
}
Dictionary DCWorldExt::annual_report_self_test() const{std::string error;return result(annual_development_self_test(error),error);}
} // namespace pk
