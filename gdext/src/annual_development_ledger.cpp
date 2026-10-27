#include "annual_development_ledger.h"
#include "runtime_ideology_pod.h"
#include <algorithm>
#include <limits>
#include <type_traits>

namespace pk {
namespace {
constexpr const char *KEYS[] = {
    "population","employed","funds","buildings","suspended","pending_buildings",
    "settlements","territory","settlement_weight","technologies","treasury",
    "satisfaction","survival","utilization","active_buildings","job_capacity",
    "revenue","input_cost","wages","wages_due","maintenance","profit","gdp",
    "household_income","household_expense","births","deaths",
    "business_tax","income_tax","consumption_tax","import_tax","export_tax",
    "subsidies","producer_support","trade_value","trade_quantity","trade_orders",
    "output","sold","discarded","climate_loss","research_purchased",
    "research_consumed","families","persons","built","removed",
    "settlements_founded","settlements_lost","settlements_upgraded",
    "settlements_downgraded","technology_equivalents","resource_extracted"
};
static_assert(sizeof(KEYS)/sizeof(KEYS[0]) == ANNUAL_METRIC_COUNT);
size_t ix(AnnualMetric m) { return static_cast<size_t>(m); }
int64_t add(int64_t a, int64_t b) {
    if (b > 0 && a > INT64_MAX-b) return INT64_MAX;
    if (b < 0 && a < INT64_MIN-b) return INT64_MIN;
    return a+b;
}
int64_t mul(int64_t a, int64_t b) {
    if (a == 0 || b == 0) return 0;
    if (a == INT64_MIN || b == INT64_MIN) return (a<0) == (b<0) ? INT64_MAX : INT64_MIN;
    const bool neg = (a<0)!=(b<0);
    a=a<0?-a:a; b=b<0?-b:b;
    if (a > INT64_MAX/b) return neg?INT64_MIN:INT64_MAX;
    return neg?-(a*b):a*b;
}
int64_t ratio(int64_t a, int64_t b, int64_t scale=ANNUAL_Q16) {
    if (b <= 0) return 0;
    return add(mul(a/b,scale),mul(a%b,scale)/b);
}
int32_t quality(int64_t value,int32_t target,int32_t weight) {
    return static_cast<int32_t>(mul(std::clamp<int64_t>(value,0,target),weight)/target);
}
int64_t growth(int64_t now,int64_t before) {
    if (before == 0) return now>0?ANNUAL_Q16:now<0?-ANNUAL_Q16:0;
    return ratio(add(now,-before),before<0?-before:before);
}
int32_t improvement(int64_t change,int64_t target,int32_t weight) {
    constexpr int64_t neutral_q16 = 16384; // No change earns 25% of this progress weight.
    int64_t fraction=change>=0 ? neutral_q16+ratio(std::min(change,target),target,65536-neutral_q16)
        : neutral_q16-ratio(std::min(-change,target),target,neutral_q16);
    return static_cast<int32_t>(mul(std::clamp<int64_t>(fraction,0,65536),weight)/65536);
}
uint64_t checksum(const uint8_t *p,size_t n) {
    uint64_t h=1469598103934665603ull;
    for(size_t i=0;i<n;++i) {h^=p[i];h*=1099511628211ull;} return h;
}

// One explicit canonical field visitor for save/hash. No struct padding or
// platform endian assumptions; reject bounds before allocating on restore.
struct Writer {
    std::vector<uint8_t> &bytes;
    template<class T> std::enable_if_t<std::is_integral_v<T>> operator()(T &v) {
        using U=std::make_unsigned_t<T>; U u=static_cast<U>(v);
        for(size_t n=0;n<sizeof(T);++n) bytes.push_back(static_cast<uint8_t>(u>>(n*8)));
    }
    void operator()(std::string &v) {uint32_t n=static_cast<uint32_t>(v.size());(*this)(n);bytes.insert(bytes.end(),v.begin(),v.end());}
    template<class T,size_t N> void operator()(std::array<T,N> &v) {for(auto &a:v) (*this)(a);}
    template<class T> void operator()(std::vector<T> &v) {uint32_t n=static_cast<uint32_t>(v.size());(*this)(n);for(auto &a:v) (*this)(a);}
    template<class T> std::enable_if_t<!std::is_integral_v<T>> operator()(T &v) {visit(*this,v);}
};
struct Reader {
    const uint8_t *p; size_t size,at=0; bool ok=true;
    template<class T> std::enable_if_t<std::is_integral_v<T>> operator()(T &v) {
        if(!ok || at>size || sizeof(T)>size-at){ok=false;return;}
        using U=std::make_unsigned_t<T>; U u=0;
        for(size_t n=0;n<sizeof(T);++n) u|=static_cast<U>(p[at++])<<(n*8); v=static_cast<T>(u);
    }
    void operator()(std::string &v) {uint32_t n=0;(*this)(n);if(!ok||n>65536||at>size||n>size-at){ok=false;return;}v.assign(reinterpret_cast<const char*>(p+at),n);at+=n;}
    template<class T,size_t N> void operator()(std::array<T,N> &v) {for(auto &a:v) (*this)(a);}
    template<class T> void operator()(std::vector<T> &v) {uint32_t n=0;(*this)(n);if(!ok||n>1048576||n>size-at){ok=false;return;}v.resize(n);for(auto &a:v){(*this)(a);if(!ok)return;}}
    template<class T> std::enable_if_t<!std::is_integral_v<T>> operator()(T &v) {visit(*this,v);}
};
template<class C> void visit(C &c,AnnualBreakdown &v){c(v.id);c(v.count);c(v.value);c(v.secondary);}
template<class C> void visit(C &c,AnnualSettlement &v){c(v.cell);c(v.tier);c(v.population);c(v.buildings);c(v.gdp);}
template<class C> void visit(C &c,AnnualEconomyFacts &v){
    c(v.country_handle);c(v.revision);c(v.day);c(v.values);c(v.tiers);
    c(v.satisfaction_dimensions);c(v.dimension_population);c(v.industries);
    c(v.professions);c(v.goods);c(v.resources);c(v.settlements);
}
template<class C> void visit(C &c,AnnualCountryFacts &v){c(v.handle);c(v.name);c(v.treasury);c(v.territory);c(v.research_purchased);c(v.research_consumed);c(v.era);c(v.technologies);}
template<class C> void visit(C &c,AnnualDevelopmentProfile &v){
    c(v.version);c(v.grade_thresholds);c(v.reward_draws);c(v.quality_weights);c(v.quality_targets);
    c(v.progress_weights);c(v.progress_targets);c(v.active_target);c(v.offer_cost);
    c(v.max_offer_cost);c(v.offer_growth_percent);c(v.technology_equivalents_q16);c(v.technology_eras);c(v.era_milestones);
}
template<class C> void visit(C &c,AnnualDevelopmentReport &v){
    c(v.id);c(v.country_handle);c(v.scoring_version);c(v.year);c(v.start_day);c(v.end_day);
    c(v.reward_q16);c(v.reward_sequence);c(v.score_bp);c(v.grade);c(v.cap);c(v.era);
    c(v.complete);c(v.reward_settled);c(v.presented);c(v.country_name);c(v.opening);c(v.closing);
    c(v.totals);c(v.quality_average);c(v.score_parts);c(v.monthly_gdp);c(v.monthly_population);
    c(v.new_technologies);c(v.industry_totals);c(v.resource_totals);c(v.first_gdp);c(v.last_gdp);c(v.first_people_days);c(v.last_people_days);c(v.first_days);c(v.last_days);
}
}
const char *annual_metric_key(size_t n){return n<ANNUAL_METRIC_COUNT?KEYS[n]:"";}
bool annual_metric_is_flow(size_t n){return (n>=ix(AnnualMetric::REVENUE)&&n<=ix(AnnualMetric::RESEARCH_CONSUMED))||n>=ix(AnnualMetric::BUILT);}
bool AnnualDevelopmentProfile::valid() const {
    int64_t q=0,p=0;for(auto w:quality_weights){if(w<0)return false;q+=w;}for(auto w:progress_weights){if(w<0)return false;p+=w;}
    if(version==0||q+p!=10000||offer_cost<0||max_offer_cost<offer_cost||offer_growth_percent<100||active_target<=0)return false;
    for(auto t:quality_targets)if(t<=0)return false;for(auto t:progress_targets)if(t<=0)return false;
    for(size_t i=0;i<7;++i)if(grade_thresholds[i]<0||grade_thresholds[i]>10000||reward_draws[i]<0||reward_draws[i]>64||(i&&grade_thresholds[i]>=grade_thresholds[i-1]))return false;
    return grade_thresholds[6]==0;
}
bool AnnualDevelopmentLedger::configure(uint64_t handle,int64_t length,int64_t initial,const AnnualDevelopmentProfile &profile,std::string &error){
    if(handle==0||length<1||length>3660||initial<0||!profile.valid()){error="annual_configuration_invalid";return false;}
    *this=AnnualDevelopmentLedger{};_handle=handle;_length=length;_tracked_since=initial;_last_day=initial-1;_profile=profile;begin_year(initial/length);return true;
}
bool AnnualDevelopmentLedger::update_profile(const AnnualDevelopmentProfile &profile,std::string &error){
    if(!configured()||!profile.valid()||profile.version<_profile.version){error="annual_profile_update_invalid";return false;}
    if(profile.version!=_profile.version){_profile=profile;_current.scoring_version=profile.version;++_revision;}
    error.clear();return true;
}
void AnnualDevelopmentLedger::seed(const AnnualEconomyFacts &f,const AnnualCountryFacts &c){
    if(!configured()||f.country_handle!=_handle||c.handle!=_handle||_economy_revision!=0)return;
    _latest=f;_country=c;_current.opening=f;_current.country_name=c.name;_current.era=c.era;
    _current.opening.values[ix(AnnualMetric::TECHNOLOGIES)]=static_cast<int64_t>(c.technologies.size());
    _current.opening.values[ix(AnnualMetric::TREASURY)]=c.treasury;_current.opening.values[ix(AnnualMetric::TERRITORY)]=c.territory;
}
void AnnualDevelopmentLedger::begin_year(int64_t y){
    _current=AnnualDevelopmentReport{};_current.id=static_cast<uint64_t>(y)+1;_current.country_handle=_handle;
    _current.scoring_version=_profile.version;_current.year=y;_current.start_day=y*_length;
    _current.end_day=(y+1)*_length-1;_current.opening=_latest;_current.country_name=_country.name;_current.era=_country.era;
    _quality_sum={};_population_days=0;_days=0;_dimension_sum={};_dimension_days={};
}
void AnnualDevelopmentLedger::observe_economy(const AnnualEconomyFacts &f){
    if(!configured()||f.country_handle!=_handle||f.revision<=_economy_revision||f.day<_current.start_day||f.day>_current.end_day)return;
    _economy_revision=f.revision;_latest=f;
    const auto merge_rows=[](std::vector<AnnualBreakdown> &into,const std::vector<AnnualBreakdown> &rows){for(const auto &r:rows){auto it=std::find_if(into.begin(),into.end(),[&](const auto &v){return v.id==r.id;});if(it==into.end()){into.push_back(r);}else{it->count=r.count;it->value=add(it->value,r.value);it->secondary=add(it->secondary,r.secondary);}}};
    merge_rows(_current.industry_totals,f.industries);merge_rows(_current.resource_totals,f.resources);
    const size_t month=static_cast<size_t>(std::clamp<int64_t>((f.day-_current.start_day)*12/_length,0,11));
    for(size_t n=0;n<ANNUAL_METRIC_COUNT;++n)if(annual_metric_is_flow(n))_current.totals[n]=add(_current.totals[n],f.values[n]);
    _current.monthly_gdp[month]=add(_current.monthly_gdp[month],f.values[ix(AnnualMetric::GDP)]);
    // Births/deaths and construction counters originate in native commit events.
    const int64_t window=(_length < 365 ? std::max<int64_t>(1,_length/4) : 30);
    if(f.day-_current.start_day<window)_current.first_gdp=add(_current.first_gdp,f.values[ix(AnnualMetric::GDP)]);
    if(_current.end_day-f.day<window)_current.last_gdp=add(_current.last_gdp,f.values[ix(AnnualMetric::GDP)]);
    ++_revision;
}
void AnnualDevelopmentLedger::commit_day(int64_t day,const AnnualCountryFacts &c,uint64_t draws){
    if(!configured()||c.handle!=_handle||day<=_last_day)return;
    // A missed day is evidence of an incomplete year, never invented history.
    if(day!=_last_day+1)_tracked_since=day;
    if(day>_current.end_day){_current.complete=0;finish_year(draws);begin_year(day/_length);}
    for(int32_t tech:c.technologies)if(std::find(_country.technologies.begin(),_country.technologies.end(),tech)==_country.technologies.end()){
        _current.new_technologies.push_back(tech);
        if(tech>=0&&static_cast<size_t>(tech)<_profile.technology_equivalents_q16.size())
            _current.totals[ix(AnnualMetric::TECHNOLOGY_EQUIVALENTS)]=add(_current.totals[ix(AnnualMetric::TECHNOLOGY_EQUIVALENTS)],_profile.technology_equivalents_q16[tech]);
    }
    _current.totals[ix(AnnualMetric::RESEARCH_PURCHASED)]=add(_current.totals[ix(AnnualMetric::RESEARCH_PURCHASED)],std::max<int64_t>(0,c.research_purchased-_country.research_purchased));
    _current.totals[ix(AnnualMetric::RESEARCH_CONSUMED)]=add(_current.totals[ix(AnnualMetric::RESEARCH_CONSUMED)],std::max<int64_t>(0,c.research_consumed-_country.research_consumed));
    _country=c;_latest.values[ix(AnnualMetric::TECHNOLOGIES)]=static_cast<int64_t>(c.technologies.size());
    _latest.values[ix(AnnualMetric::TREASURY)]=c.treasury;_latest.values[ix(AnnualMetric::TERRITORY)]=c.territory;
    _current.era=c.era;_current.country_name=c.name;
    for(size_t era=0;era<_profile.era_milestones.size();++era)if(std::find(c.technologies.begin(),c.technologies.end(),_profile.era_milestones[era])!=c.technologies.end())_current.era=std::max<int32_t>(_current.era,std::min<int32_t>(10,static_cast<int32_t>(era)+1));
    _country.era=_current.era;
    const int64_t people=std::max<int64_t>(0,_latest.values[ix(AnnualMetric::POPULATION)]);
    const int64_t employment=ratio(_latest.values[ix(AnnualMetric::EMPLOYED)],people);
    const int64_t operating=(std::clamp<int64_t>(_latest.values[ix(AnnualMetric::UTILIZATION)],0,_profile.quality_targets[3])*65536/_profile.quality_targets[3]
        +std::clamp<int64_t>(_latest.values[ix(AnnualMetric::ACTIVE_BUILDINGS)],0,_profile.active_target)*65536/_profile.active_target)/2;
    const std::array<int64_t,4> quality_values{{_latest.values[ix(AnnualMetric::SATISFACTION)],_latest.values[ix(AnnualMetric::SURVIVAL)],employment,operating}};
    for(size_t i=0;i<4;++i)_quality_sum[i]=add(_quality_sum[i],mul(quality_values[i],people));
    _population_days=add(_population_days,people);++_days;
    for(size_t i=0;i<8;++i){_dimension_sum[i]=add(_dimension_sum[i],mul(std::max<int64_t>(0,_latest.satisfaction_dimensions[i]),_latest.dimension_population[i]));_dimension_days[i]=add(_dimension_days[i],_latest.dimension_population[i]);}
    const auto month=static_cast<size_t>(std::clamp<int64_t>((day-_current.start_day)*12/_length,0,11));
    _current.monthly_population[month]=people;
    const int64_t window=(_length < 365 ? std::max<int64_t>(1,_length/4) : 30);
    if(day-_current.start_day<window){++_current.first_days;_current.first_people_days=add(_current.first_people_days,people);}
    if(_current.end_day-day<window){++_current.last_days;_current.last_people_days=add(_current.last_people_days,people);}
    _last_day=day;++_revision;
    if(day==_current.end_day){_current.complete=_tracked_since<=_current.start_day&&_days==_length;finish_year(draws);begin_year(day/_length+1);}
}
void AnnualDevelopmentLedger::finish_year(uint64_t draws){
    _current.closing=_latest;
    for(size_t n=0;n<ANNUAL_METRIC_COUNT;++n)if(!annual_metric_is_flow(n))_current.totals[n]=_latest.values[n];
    for(size_t i=0;i<4;++i)_current.quality_average[i]=_population_days>0?_quality_sum[i]/_population_days:0;
    for(size_t i=0;i<8;++i)_current.closing.satisfaction_dimensions[i]=_dimension_days[i]>0?_dimension_sum[i]/_dimension_days[i]:-1;
    const auto *previous=_reports.empty()?nullptr:&_reports.back();
    evaluate(_current,previous,_profile,draws);
    _current.reward_sequence=_current.id;
    if(!_current.complete||_current.reward_q16==0)_current.reward_settled=1;
    _reports.push_back(_current);++_revision;
}
void AnnualDevelopmentLedger::evaluate(AnnualDevelopmentReport &r,const AnnualDevelopmentReport *prev,const AnnualDevelopmentProfile &p,uint64_t draws){
    if(!r.complete){r.score_bp=0;r.grade=6;r.reward_q16=0;return;}
    for(size_t i=0;i<4;++i)r.score_parts[i]=quality(r.quality_average[i],i==3?65536:p.quality_targets[i],p.quality_weights[i]);
    const bool comparable=prev&&prev->complete&&prev->year+1==r.year;
    int64_t gdp_growth=0,pc_growth=0;
    if(comparable){
        gdp_growth=growth(r.totals[ix(AnnualMetric::GDP)],prev->totals[ix(AnnualMetric::GDP)]);
        // Match the report's explicit annual GDP / year-end population basis.
        pc_growth=growth(ratio(r.totals[ix(AnnualMetric::GDP)],r.closing.values[ix(AnnualMetric::POPULATION)],10000),ratio(prev->totals[ix(AnnualMetric::GDP)],prev->closing.values[ix(AnnualMetric::POPULATION)],10000));
    }else{
        gdp_growth=growth(ratio(r.last_gdp,r.last_days,10000),ratio(r.first_gdp,r.first_days,10000));
        pc_growth=growth(ratio(r.last_gdp,r.last_people_days,10000),ratio(r.first_gdp,r.first_people_days,10000));
    }
    const std::array<int64_t,6> changes{{gdp_growth,pc_growth,
        growth(r.closing.values[ix(AnnualMetric::POPULATION)],r.opening.values[ix(AnnualMetric::POPULATION)]),
        growth(r.closing.values[ix(AnnualMetric::BUILDINGS)],r.opening.values[ix(AnnualMetric::BUILDINGS)]),
        growth(r.closing.values[ix(AnnualMetric::SETTLEMENT_WEIGHT)],r.opening.values[ix(AnnualMetric::SETTLEMENT_WEIGHT)]),
        r.totals[ix(AnnualMetric::TECHNOLOGY_EQUIVALENTS)]}};
    for(size_t i=0;i<6;++i)r.score_parts[i+4]=improvement(changes[i],p.progress_targets[i],p.progress_weights[i]);
    if(!p.technology_equivalents_q16.empty()&&r.closing.values[ix(AnnualMetric::TECHNOLOGIES)]>=static_cast<int64_t>(p.technology_equivalents_q16.size()))r.score_parts[9]=p.progress_weights[5];
    r.score_bp=0;for(auto part:r.score_parts)r.score_bp+=part;
    r.grade=6;for(int32_t i=0;i<7;++i)if(r.score_bp>=p.grade_thresholds[i]){r.grade=i;break;}
    r.cap=r.quality_average[1]<39322?5:r.quality_average[1]<52429?3:-1;
    if(r.cap>=0)r.grade=std::max(r.grade,r.cap);
    r.reward_q16=0;
    for(int32_t n=0;n<p.reward_draws[r.grade];++n)r.reward_q16=add(r.reward_q16,runtime_ideology_offer_cost_q16(p.offer_cost,p.offer_growth_percent,p.max_offer_cost,draws+static_cast<uint64_t>(n)));
    if(r.grade==5)r.reward_q16=runtime_ideology_offer_cost_q16(p.offer_cost,p.offer_growth_percent,p.max_offer_cost,draws)/2;
    r.reward_q16=r.reward_q16/10;
}
bool AnnualDevelopmentLedger::has_pending_reward() const{while(_reward_cursor<_reports.size()&&_reports[_reward_cursor].reward_settled)++_reward_cursor;return _reward_cursor<_reports.size();}
uint64_t AnnualDevelopmentLedger::ready_report_id() const{while(_ready_cursor<_reports.size()&&_reports[_ready_cursor].presented)++_ready_cursor;return _ready_cursor<_reports.size()&&_reports[_ready_cursor].reward_settled?_reports[_ready_cursor].id:0;}
AnnualDevelopmentReport *AnnualDevelopmentLedger::pending_reward(){return has_pending_reward()?&_reports[_reward_cursor]:nullptr;}
bool AnnualDevelopmentLedger::settle_reward(uint64_t seq){for(auto &r:_reports)if(r.reward_sequence==seq){if(!r.reward_settled){r.reward_settled=1;++_revision;}return true;}return false;}
bool AnnualDevelopmentLedger::mark_presented(uint64_t id){for(auto &r:_reports)if(r.id==id&&r.reward_settled){if(!r.presented){r.presented=1;++_revision;}return true;}return false;}
void AnnualDevelopmentLedger::encode(std::vector<uint8_t> &bytes) const {
    bytes.clear();auto copy=*this;Writer c{bytes};uint32_t magic=0x52414b50,version=1;c(magic);c(version);
    c(copy._handle);c(copy._revision);c(copy._economy_revision);c(copy._length);c(copy._last_day);c(copy._tracked_since);
    c(copy._profile);c(copy._latest);c(copy._country);c(copy._current);c(copy._quality_sum);c(copy._population_days);c(copy._days);c(copy._dimension_sum);c(copy._dimension_days);c(copy._reports);
    auto hash=checksum(bytes.data(),bytes.size());c(hash);
}
bool AnnualDevelopmentLedger::restore(const uint8_t *bytes,size_t size,std::string &error){
    if(size<16||size>512u*1024u*1024u){error="annual_save_size_invalid";return false;}
    Reader tail{bytes+size-8,8};uint64_t expected=0;tail(expected);
    if(checksum(bytes,size-8)!=expected){error="annual_save_checksum_mismatch";return false;}
    AnnualDevelopmentLedger next;Reader c{bytes,size-8};uint32_t magic=0,version=0;c(magic);c(version);
    if(magic!=0x52414b50||version!=1){error="annual_save_version_invalid";return false;}
    c(next._handle);c(next._revision);c(next._economy_revision);c(next._length);c(next._last_day);c(next._tracked_since);
    c(next._profile);c(next._latest);c(next._country);c(next._current);c(next._quality_sum);c(next._population_days);c(next._days);c(next._dimension_sum);c(next._dimension_days);c(next._reports);
    if(!c.ok||c.at!=c.size||!next._profile.valid()||next._handle==0||next._length<1||next._length>3660||next._days<0||next._days>next._length||next._last_day<next._tracked_since-1||next._current.year!=((next._last_day+1)/next._length)||next._current.country_handle!=next._handle){error="annual_save_payload_invalid";return false;}
    for(size_t i=0;i<next._reports.size();++i){const auto &r=next._reports[i];if(r.country_handle!=next._handle||r.id!=static_cast<uint64_t>(r.year)+1||r.grade<0||r.grade>6||r.score_bp<0||r.score_bp>10000||r.reward_q16<0||r.reward_sequence!=r.id||r.start_day!=r.year*next._length||r.end_day!=r.start_day+next._length-1||(i&&r.year<=next._reports[i-1].year)){error="annual_save_report_invalid";return false;}}
    if(configured()){
        if(_handle!=next._handle||_length!=next._length){error="annual_save_identity_mismatch";return false;}
        const bool v1_to_v2=next._profile.version==1&&_profile.version==2;
        if(_profile.version!=next._profile.version&&!v1_to_v2){error="annual_save_identity_mismatch";return false;}
        // Completed reports retain their frozen scores and rewards. The open
        // year contains raw accumulators, so it can continue under v2.
        if(v1_to_v2){next._profile=_profile;next._current.scoring_version=_profile.version;}
    }
    *this=std::move(next);return true;
}
bool annual_development_self_test(std::string &error){
    AnnualDevelopmentProfile p;AnnualDevelopmentProfile legacy=p;
    legacy.version=1;legacy.grade_thresholds={{9400,8600,7500,6000,4500,3000,0}};
    legacy.reward_draws={{6,4,3,2,1,0,0}};
    legacy.quality_targets={{62259,64225,62259,55706}};
    AnnualDevelopmentLedger ledger;
    if(!ledger.configure(7,4,0,legacy,error))return false;
    AnnualEconomyFacts f;f.country_handle=7;f.values[ix(AnnualMetric::POPULATION)]=100;f.values[ix(AnnualMetric::EMPLOYED)]=100;f.values[ix(AnnualMetric::SATISFACTION)]=65536;f.values[ix(AnnualMetric::SURVIVAL)]=65536;f.values[ix(AnnualMetric::UTILIZATION)]=65536;f.values[ix(AnnualMetric::ACTIVE_BUILDINGS)]=65536;
    AnnualCountryFacts country;country.handle=7;country.name="Test";ledger.seed(f,country);
    for(int64_t d=0;d<4;++d){f.day=d;f.revision=static_cast<uint64_t>(d)+1;f.values[ix(AnnualMetric::GDP)]=100+d*10;ledger.observe_economy(f);ledger.observe_economy(f);ledger.commit_day(d,country,0);}
    if(ledger.reports().size()!=1||ledger.reports()[0].totals[ix(AnnualMetric::GDP)]!=460||!ledger.reports()[0].complete){error="annual_commit_dedupe_failed";return false;}
    const auto seq=ledger.reports()[0].reward_sequence;ledger.settle_reward(seq);ledger.settle_reward(seq);
    std::vector<uint8_t> bytes;ledger.encode(bytes);AnnualDevelopmentLedger restored;
    if(!restored.restore(bytes.data(),bytes.size(),error)||restored.reports().size()!=1||!restored.reports()[0].reward_settled){error="annual_roundtrip_failed";return false;}
    AnnualDevelopmentProfile upgraded=p;upgraded.version=2;
    AnnualDevelopmentLedger migrated;
    if(!migrated.configure(7,4,4,upgraded,error)||!migrated.restore(bytes.data(),bytes.size(),error)||
       migrated.reports().size()!=1||migrated.reports()[0].scoring_version!=1||
       migrated.current().scoring_version!=2){error="annual_profile_v1_to_v2_migration_failed";return false;}
    AnnualDevelopmentLedger live_update;
    if(!live_update.configure(7,4,4,legacy,error)||!live_update.update_profile(p,error)||
       live_update.current().scoring_version!=2){error="annual_live_profile_update_failed";return false;}
    bytes[15]^=1;if(restored.restore(bytes.data(),bytes.size(),error)){error="annual_corruption_accepted";return false;}
    AnnualDevelopmentReport r=ledger.reports()[0];r.quality_average[1]=30000;AnnualDevelopmentLedger::evaluate(r,nullptr,p,3);
    if(r.grade<5){error="annual_survival_cap_failed";return false;}
    AnnualDevelopmentReport stagnant;stagnant.complete=1;
    AnnualDevelopmentLedger::evaluate(stagnant,nullptr,p,0);
    if(stagnant.score_parts[4]!=200||stagnant.score_parts[5]!=150||
       stagnant.score_parts[6]!=125||stagnant.score_parts[7]!=75||
       stagnant.score_parts[8]!=75||stagnant.score_parts[9]!=125){error="annual_stagnation_score_failed";return false;}
    // Exercise both sides of every grade boundary with an independently
    // controlled quality score and the reduced escalating draw-price reward.
    AnnualDevelopmentProfile boundaries=p;
    boundaries.quality_weights={{10000,0,0,0}};
    boundaries.progress_weights={{0,0,0,0,0,0}};
    boundaries.quality_targets[0]=65536;
    boundaries.offer_cost=100*65536;boundaries.offer_growth_percent=200;
    boundaries.max_offer_cost=INT64_MAX;
    for(int32_t grade=0;grade<7;++grade){
        for(int32_t offset: {0,-1}){
            const int32_t score=boundaries.grade_thresholds[grade]+offset;
            if(score<0)continue;
            AnnualDevelopmentReport sample;sample.complete=1;
            sample.quality_average[0]=(static_cast<int64_t>(score)*65536+9999)/10000;
            sample.quality_average[1]=65536;
            AnnualDevelopmentLedger::evaluate(sample,nullptr,boundaries,2);
            const int32_t expected=offset==0?grade:grade+1;
            int64_t reward=0,price=400*65536;
            for(int32_t n=0;n<boundaries.reward_draws[expected];++n){reward+=price;price*=2;}
            if(expected==5)reward=200*65536;
            reward/=10;
            if(sample.score_bp!=score||sample.grade!=expected||sample.reward_q16!=reward){error="annual_grade_boundary_or_reward_failed";return false;}
        }
    }
    // A partial legacy year never receives a reward, even with perfect quality.
    AnnualDevelopmentLedger partial;
    if(!partial.configure(7,4,2,p,error))return false;
    f.revision=10;f.day=2;partial.seed(f,country);partial.observe_economy(f);partial.commit_day(2,country,0);
    std::vector<uint8_t> checkpoint;partial.encode(checkpoint);
    AnnualDevelopmentLedger continuation;
    if(!continuation.restore(checkpoint.data(),checkpoint.size(),error))return false;
    f.revision=11;f.day=3;continuation.observe_economy(f);continuation.commit_day(3,country,0);
    if(continuation.reports().size()!=1||continuation.reports()[0].complete||continuation.reports()[0].reward_q16!=0||!continuation.reports()[0].reward_settled){error="annual_partial_checkpoint_failed";return false;}
    error.clear();return true;
}
} // namespace pk
