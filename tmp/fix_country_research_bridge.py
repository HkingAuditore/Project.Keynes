from pathlib import Path
p=Path('gdext/src/country_runtime.cpp');s=p.read_text()
a=s.index('bool NativeCountryRuntime::research_procurement_policy(');b=s.index('\nuint64_t NativeCountryRuntime::begin_economy_asset_transaction',a);f=s[a:b]
prefix='''    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_asset_snapshot() : nullptr;
'''
for name in ['research_auto_purchase','research_daily_budgets','research_queues','research_queue_lengths','research_deferred_points']:
 prefix+=f'    const auto &_country_{name} = worker ? worker->{name} : this->_country_{name};\n'
prefix+='    const auto &_country_goods = worker ? worker->country_goods : this->_country_goods;\n'
f=f.replace('    if (country_slot < 0',prefix+'    if (country_slot < 0',1)
f=f.replace('0, effective_research_cost(country_slot, tech) -\n                progress_for(country_slot, tech)', '''0, (worker ? country_effective_research_cost(
                    _technology_costs[tech], worker->research_cost_factor[slot])
                    : effective_research_cost(country_slot, tech)) -
                (worker ? worker->research_progress[slot * worker->technology_count + tech]
                    : progress_for(country_slot, tech))''')
s=s[:a]+f+s[b:]
for method,field in [('total_good','country_goods'),('research_consumed_total','research_consumed_total')]:
 a=s.index('int64_t NativeCountryRuntime::'+method+'(');b=s.index('\n}\n',a)+3;f=s[a:b]
 var='_country_goods' if method=='total_good' else '_country_research_consumed_total'
 prefix='''    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_asset_snapshot() : nullptr;
'''+f'    const auto &{var} = worker ? worker->{field} : this->{var};\n'
 f=f.replace('    int64_t total = 0;',prefix+'    int64_t total = 0;');s=s[:a]+f+s[b:]
a=s.index('int64_t NativeCountryRuntime::cash_for_slot(');b=s.index('\n}\n',a)+3;f=s[a:b];f=f.replace('    return country_slot', '''    if (_simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)) {
        const auto snapshot = _simulation_host->country_asset_snapshot();
        if (snapshot) return country_slot >= 0 &&
            static_cast<size_t>(country_slot) < snapshot->country_cash.size() &&
            snapshot->country_active[country_slot] != 0
            ? snapshot->country_cash[country_slot] : 0;
    }
    return country_slot''');s=s[:a]+f+s[b:];p.write_text(s)
