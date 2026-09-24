from pathlib import Path
p=Path('gdext/src/country_runtime.cpp');s=p.read_text();a=s.index('bool NativeCountryRuntime::copy_economy_snapshot');b=s.index('\nuint64_t NativeCountryRuntime::catalog_hash',a);f=s[a:b]
prefix='''
    // Pin one immutable Country commit for the whole economic freeze. The
    // legacy store stops advancing as soon as the worker owns Country.
    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_asset_snapshot() : nullptr;
'''
fields=['cell_country_slot','country_technologies','country_tax_defaults','country_tax_default_modes','cell_tax_policy_ids']
for kind in ['income','consumption','business','import','export']:
 fields += ['country_'+kind+'_tax_overrides','country_'+kind+'_tax_mode_overrides']
for name in fields:
 prefix+=f'    const auto &_{name} = worker ? worker->{name} : this->_{name};\n'
f=f.replace('    if (!economy_available()) return false;', '    if (!economy_available()) return false;'+prefix)
f=f.replace('    out.country_handles.resize(_countries.active.size());\n    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {\n        out.country_handles[slot] = _countries.active[slot] != 0\n            ? make_handle(static_cast<int32_t>(slot)) : 0;\n    }', '''    const auto &active = worker ? worker->country_active : _countries.active;
    const auto &generations = worker ? worker->country_generation : _countries.generation;
    out.country_handles.resize(active.size());
    for (size_t slot = 0; slot < active.size(); ++slot)
        out.country_handles[slot] = active[slot] != 0
            ? (uint64_t{generations[slot]} << 32u) | static_cast<uint32_t>(slot) : 0;''')
f=f.replace('out.country_count = static_cast<int32_t>(_countries.active.size());','out.country_count = static_cast<int32_t>(active.size());')
f=f.replace('    out.cell_tax_policies = _cell_tax_policies;', '''    if (worker) {
        out.cell_tax_policies.clear();
        for (const auto &policy : worker->cell_tax_policies) {
            CellTaxPolicy row;
            row.defaults = policy.defaults;
            row.default_modes = policy.modes;
            for (const auto &v : policy.overrides)
                row.overrides.push_back({v.kind, v.item, v.rate, v.mode});
            out.cell_tax_policies.push_back(std::move(row));
        }
    } else {
        out.cell_tax_policies = _cell_tax_policies;
    }''')
f=f.replace('out.tax_policy_version = _tax_policy_version;', 'out.tax_policy_version = worker ? worker->generation : _tax_policy_version;').replace('out.generation = _generation;', 'out.generation = worker ? worker->generation : _generation;').replace('out.state_hash = compute_state_hash();', 'out.state_hash = worker ? worker->state_hash : compute_state_hash();')
s=s[:a]+f+s[b:];p.write_text(s)
