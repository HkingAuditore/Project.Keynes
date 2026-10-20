#include "economy_runtime.h"
#include "native_simulation_host.h"
#include "country_runtime.h"
#include "economy_cost_probe.h"
#include <algorithm>

namespace pk {
namespace { size_t ai(AnnualMetric m){return static_cast<size_t>(m);} }
bool NativeEconomyRuntime::annual_observes_cell(int32_t cell) const {
    if(!_simulation_host||!_simulation_host->annual_development_enabled()||cell<0||static_cast<size_t>(cell)>=_epoch_cell_country.size())return false;
    const int32_t country=_epoch_cell_country[cell];
    return country>=0&&static_cast<size_t>(country)<_epoch_country_handles.size()&&_epoch_country_handles[country]==_simulation_host->annual_country_handle();
}
void NativeEconomyRuntime::record_annual_event(int32_t cell,AnnualMetric metric,int64_t value){
    if(!annual_observes_cell(cell))return;
    auto &target=_annual_epoch_events[ai(metric)];target=saturating_add(target,value,_saturation_count);
}
AnnualEconomyFacts NativeEconomyRuntime::capture_annual_facts(uint64_t handle,bool flows) const {
    AnnualEconomyFacts f;f.country_handle=handle;f.day=_sample_day;f.revision=static_cast<uint64_t>(_epoch_id.get());
    const auto found=std::find(_epoch_country_handles.begin(),_epoch_country_handles.end(),handle);
    if(found==_epoch_country_handles.end())return f;
    const int32_t country=static_cast<int32_t>(found-_epoch_country_handles.begin());
    int64_t saturation=0,sat_sum=0,survival_sum=0,util_sum=0;
    const auto plus=[&](AnnualMetric m,int64_t v){f.values[ai(m)]=saturating_add(f.values[ai(m)],v,saturation);};
    std::vector<uint8_t> settled(static_cast<size_t>(_cell_count.get()),0),produced(settled.size(),0);
    for(auto cell:_epoch_settlement_cells)if(cell>=0&&static_cast<size_t>(cell)<settled.size())settled[cell]=1;
    for(auto cell:_epoch_building_cells)if(cell>=0&&static_cast<size_t>(cell)<produced.size())produced[cell]=1;
    f.industries.resize(_building_types.size());for(size_t i=0;i<f.industries.size();++i)f.industries[i].id=static_cast<int32_t>(i);
    f.professions.resize(_profession_ids.size());for(size_t i=0;i<f.professions.size();++i)f.professions[i].id=static_cast<int32_t>(i);
    const auto &pop=population_store();
    std::vector<int32_t> owned_cells;
    for(int32_t cell=0;cell<_cell_count.get();++cell){
        if(static_cast<size_t>(cell)>=_epoch_cell_country.size()||_epoch_cell_country[cell]!=country)continue;
        owned_cells.push_back(cell);
        plus(AnnualMetric::TERRITORY,1);AnnualSettlement town;town.cell=cell;
        pop.for_each_in_cell(cell,[&](int32_t slot){
            const int64_t people=std::max<int64_t>(0,pop.population[slot]);if(people==0)return;
            plus(AnnualMetric::POPULATION,people);town.population=saturating_add(town.population,people,saturation);
            plus(AnnualMetric::EMPLOYED,std::max<int64_t>(0,pop.owner_employed[slot])+std::max<int64_t>(0,pop.employee_employed[slot]));
            plus(AnnualMetric::FUNDS,pop.funds[slot]);
            sat_sum=saturating_add(sat_sum,saturating_mul(people,static_cast<int64_t>(pop.composite_satisfaction[slot]),saturation),saturation);
            survival_sum=saturating_add(survival_sum,saturating_mul(people,static_cast<int64_t>(pop.needs_satisfaction[slot]),saturation),saturation);
            const uint8_t mask=satisfaction_applicable_mask(slot);
            for(int32_t dim=0;dim<std::min<int32_t>(8,SAT_DIM_COUNT);++dim)if(mask&(1U<<dim)){
                f.dimension_population[dim]=saturating_add(f.dimension_population[dim],people,saturation);
                f.satisfaction_dimensions[dim]=saturating_add(f.satisfaction_dimensions[dim],saturating_mul(people,static_cast<int64_t>(pop.satisfaction_dims[static_cast<size_t>(slot)*SAT_DIM_COUNT+dim]),saturation),saturation);
            }
            const int32_t sig=pop.signature_id[slot];
            if(sig>=0&&static_cast<size_t>(sig)<_signatures.size()){
                const int32_t prof=_signatures[sig].profession_id;
                if(prof>=0&&static_cast<size_t>(prof)<f.professions.size()){
                    auto &r=f.professions[prof];r.count=saturating_add(r.count,people,saturation);
                    r.value=saturating_add(r.value,saturating_mul(people,static_cast<int64_t>(pop.composite_satisfaction[slot]),saturation),saturation);
                    r.secondary=saturating_add(r.secondary,pop.funds[slot],saturation);
                }
            }
            if(flows&&settled[cell]){plus(AnnualMetric::HOUSEHOLD_INCOME,pop.epoch_income[slot]);plus(AnnualMetric::HOUSEHOLD_EXPENSE,pop.epoch_expense[slot]);}
        });
        if(cell<static_cast<int32_t>(_settlements.tier.size()))town.tier=std::clamp<int32_t>(_settlements.tier[cell],0,7);
        if(town.population>0){++f.tiers[town.tier];plus(AnnualMetric::SETTLEMENTS,1);plus(AnnualMetric::SETTLEMENT_WEIGHT,town.tier);}
        if(_building_cell_offsets.size()==static_cast<size_t>(_cell_count.get())+1){
            for(int32_t g=_building_cell_offsets[cell];g<_building_cell_offsets[cell+1];++g){
                const auto b=building_view(static_cast<size_t>(g));if(b.count<=0||b.type_id<0||static_cast<size_t>(b.type_id)>=f.industries.size())continue;
                plus(AnnualMetric::BUILDINGS,b.count);town.buildings=saturating_add(town.buildings,b.count,saturation);
                if(b.operating_state==1)plus(AnnualMetric::SUSPENDED,b.count);
                util_sum=saturating_add(util_sum,saturating_mul(b.operating_state==1?0:std::clamp<int64_t>(b.planned_utilization_q16,0,Q16_ONE),b.count,saturation),saturation);
                int64_t jobs=0,filled=0;group_job_totals(b,jobs,filled,saturation);plus(AnnualMetric::JOB_CAPACITY,jobs);
                auto &sector=f.industries[b.type_id];sector.count=saturating_add(sector.count,b.count,saturation);
                const int64_t value=b.last_revenue-b.last_input_cost-b.last_maintenance_cost;
                town.gdp=saturating_add(town.gdp,value,saturation);
                if(flows&&static_cast<size_t>(b.type_id)<_annual_epoch_industries.size()){
                    sector.value=_annual_epoch_industries[b.type_id].value;
                    sector.secondary=_annual_epoch_industries[b.type_id].secondary;
                }
            }
        }
        if(town.population>0)f.settlements.push_back(town);
        if(flows){
            for(int32_t kind=0;kind<ACTIVE_TAX_KIND_COUNT;++kind){const size_t lane=static_cast<size_t>(cell)*ACTIVE_TAX_KIND_COUNT+kind;
                if(lane>=_fiscal_epoch_collected.size())continue;
                const AnnualMetric m=kind==NativeCountryRuntime::TAX_INCOME?AnnualMetric::INCOME_TAX:kind==NativeCountryRuntime::TAX_CONSUMPTION?AnnualMetric::CONSUMPTION_TAX:AnnualMetric::BUSINESS_TAX;
                plus(m,_fiscal_epoch_collected[lane]);plus(AnnualMetric::SUBSIDIES,_fiscal_epoch_paid[lane]);
            }
        }
    }
    for(const auto pending:pending_construction())if(pending.cell>=0&&static_cast<size_t>(pending.cell)<_epoch_cell_country.size()&&_epoch_cell_country[pending.cell]==country)plus(AnnualMetric::PENDING_BUILDINGS,std::max<int64_t>(0,pending.count));
    const auto people=f.values[ai(AnnualMetric::POPULATION)],units=f.values[ai(AnnualMetric::BUILDINGS)];
    f.values[ai(AnnualMetric::SATISFACTION)]=people>0?sat_sum/people:0;
    f.values[ai(AnnualMetric::SURVIVAL)]=people>0?survival_sum/people:0;
    f.values[ai(AnnualMetric::UTILIZATION)]=units>0?util_sum/units:0;
    f.values[ai(AnnualMetric::ACTIVE_BUILDINGS)]=units>0?mul_div_sat(units-f.values[ai(AnnualMetric::SUSPENDED)],Q16_ONE,units,saturation):0;
    for(size_t dim=0;dim<8;++dim)f.satisfaction_dimensions[dim]=f.dimension_population[dim]>0?f.satisfaction_dimensions[dim]/f.dimension_population[dim]:-1;
    for(auto &r:f.professions)r.value=r.count>0?r.value/r.count:0;
    const auto &families=families_store();for(size_t i=0;i<families.active.size();++i)if(families.active[i]&&families.home_cell[i]>=0&&static_cast<size_t>(families.home_cell[i])<_epoch_cell_country.size()&&_epoch_cell_country[families.home_cell[i]]==country)plus(AnnualMetric::FAMILIES,1);
    const auto &persons=persons_store();for(size_t i=0;i<persons.active.size();++i)if(persons.active[i]){
        int32_t slot=-1;if(!pop.valid_handle(persons.cohort_handle[i],slot))continue;
        const int32_t cell=pop.page_cell[slot/COHORT_PAGE_SIZE];
        if(cell>=0&&static_cast<size_t>(cell)<_epoch_cell_country.size()&&_epoch_cell_country[cell]==country)plus(AnnualMetric::PERSONS,1);
    }
    if(flows){
        for(size_t n=0;n<ANNUAL_METRIC_COUNT;++n)if(annual_metric_is_flow(n))f.values[n]=saturating_add(f.values[n],_annual_epoch_events[n],saturation);
        for(size_t row=0;row<_country_partner_trade.countries.size();++row)if(_country_partner_trade.countries[row]==country&&_country_partner_trade.batch_epoch[row]==_epoch_id.get()){
            plus(AnnualMetric::TRADE_VALUE,_country_partner_trade.batch_import_base[row]+_country_partner_trade.batch_export_base[row]);
            plus(AnnualMetric::TRADE_QUANTITY,_country_partner_trade.batch_import_quantity[row]+_country_partner_trade.batch_export_quantity[row]);
            plus(AnnualMetric::TRADE_ORDERS,_country_partner_trade.batch_order_count[row]);
        }
        for(size_t row=0;row<_tariff_epoch_cells.size();++row){const auto cell=_tariff_epoch_cells[row];if(cell>=0&&static_cast<size_t>(cell)<_epoch_cell_country.size()&&_epoch_cell_country[cell]==country){plus(_tariff_epoch_kinds[row]==0?AnnualMetric::IMPORT_TAX:AnnualMetric::EXPORT_TAX,_tariff_epoch_collected[row]);plus(AnnualMetric::SUBSIDIES,_tariff_epoch_paid[row]);}}
    }
    std::vector<AnnualBreakdown> resource_rows(_resource_ids.size());
    for(size_t i=0;i<resource_rows.size();++i)resource_rows[i].id=static_cast<int32_t>(i);
    const auto &remaining=resource_remaining_lanes();const auto &delta=resource_delta_lanes();
    const auto &resource_generation=resource_lane_generation_lanes();
    const auto &resource_stock=resource_stock_lanes();
    for(size_t r=0;r<resource_rows.size();++r)for(int32_t cell:owned_cells){
        const size_t at=r*static_cast<size_t>(_cell_count.get())+cell;
        const bool current=at<resource_generation.size()&&resource_generation[at]==_resource_current_generation;
        const int64_t stock=current&&at<remaining.size()?remaining[at]:at<resource_stock.size()?resource_stock[at]:0;
        resource_rows[r].count=saturating_add(resource_rows[r].count,std::max<int64_t>(0,stock),saturation);
        if(flows&&current&&at<delta.size()&&delta[at]<0){resource_rows[r].value=saturating_add(resource_rows[r].value,-delta[at],saturation);plus(AnnualMetric::RESOURCE_EXTRACTED,-delta[at]);}
    }
    for(const auto &r:resource_rows)if(r.count||r.value)f.resources.push_back(r);
    const auto &market=market_store();
    std::vector<AnnualBreakdown> goods(static_cast<size_t>(market.good_count.get()));
    for(size_t i=0;i<goods.size();++i)goods[i].id=static_cast<int32_t>(i);
    for(int32_t cell:owned_cells){
        const int32_t m=market.cell_to_market[cell];if(m<0)continue;
        for(int32_t g=0;g<market.good_count.get();++g){
            const int64_t lane=market.index(m,g);auto &row=goods[g];
            row.count=saturating_add(row.count,std::max<int64_t>(0,market.stock[lane]),saturation);
            row.value=saturating_add(row.value,mul_div_sat(std::max<int64_t>(0,market.stock[lane]),std::max<int64_t>(0,market.price[lane]),GOODS_SCALE,saturation),saturation);
            if(lane<static_cast<int64_t>(market.last_shortage_q16.size()))row.secondary=std::max<int64_t>(row.secondary,market.last_shortage_q16[lane]);
        }
    }
    for(const auto &g:goods)if(g.count||g.secondary)f.goods.push_back(g);
    if(flows)for(size_t i=0;i<_annual_epoch_industries.size();++i){
        const auto &r=_annual_epoch_industries[i];if(r.value==0&&r.secondary==0)continue;
        auto &row=f.industries[i];row.id=static_cast<int32_t>(i);row.value=r.value;row.secondary=r.secondary;
    }
    f.industries.erase(std::remove_if(f.industries.begin(),f.industries.end(),[](const auto&r){return r.count==0&&r.value==0;}),f.industries.end());
    f.professions.erase(std::remove_if(f.professions.begin(),f.professions.end(),[](const auto&r){return r.count==0;}),f.professions.end());
    return f;
}
void NativeEconomyRuntime::publish_annual_development_facts(){
    if(!_simulation_host||!_simulation_host->annual_development_enabled())return;
    EconomyCostProbe probe("publish.annual", _current_day.get());
    _simulation_host->publish_annual_economy(capture_annual_facts(_simulation_host->annual_country_handle(),true));
}
void NativeEconomyRuntime::record_annual_production(int32_t cell){
    if(!annual_observes_cell(cell)||_building_cell_offsets.size()!=static_cast<size_t>(_cell_count.get())+1)return;
    if(_annual_epoch_industries.size()!=_building_types.size())_annual_epoch_industries.resize(_building_types.size());
    const auto record=[&](AnnualMetric m,int64_t v){record_annual_event(cell,m,v);};
    for(int32_t g=_building_cell_offsets[cell];g<_building_cell_offsets[cell+1];++g){
        const auto b=building_view(static_cast<size_t>(g));if(b.count<=0||b.type_id<0||static_cast<size_t>(b.type_id)>=_annual_epoch_industries.size())continue;
        const int64_t gdp=b.last_revenue-b.last_input_cost-b.last_maintenance_cost;
        record(AnnualMetric::REVENUE,b.last_revenue);record(AnnualMetric::INPUT_COST,b.last_input_cost);
        record(AnnualMetric::WAGES,b.last_wages_paid);record(AnnualMetric::WAGES_DUE,b.last_wages_due);
        record(AnnualMetric::MAINTENANCE,b.last_maintenance_cost);record(AnnualMetric::GDP,gdp);
        record(AnnualMetric::PROFIT,gdp-b.last_wages_paid);record(AnnualMetric::PRODUCER_SUPPORT,b.last_producer_support_receipt);
        record(AnnualMetric::OUTPUT,b.last_output);record(AnnualMetric::SOLD,b.last_sold);
        record(AnnualMetric::DISCARDED,b.last_discarded);record(AnnualMetric::CLIMATE_LOSS,b.last_climate_lost_output);
        auto &row=_annual_epoch_industries[b.type_id];row.id=b.type_id;
        row.value=saturating_add(row.value,gdp,_saturation_count);row.secondary=saturating_add(row.secondary,b.last_wages_paid,_saturation_count);
    }
}
} // namespace pk
