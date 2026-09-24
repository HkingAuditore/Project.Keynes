from pathlib import Path
p=Path('Project/project-keynes/scripts/game/player_controller.gd')
s=p.read_text(encoding='utf-8'); a=s.index('func _next_effective_day()'); b=s.index('\n\nstatic func',a)
s=s[:a]+'func _next_effective_day() -> int:\n\treturn maxi(0, _world_clock.day_index() + 1) if _world_clock != null else 0\n'+s[b:]; p.write_text(s,encoding='utf-8')
p=Path('gdext/src/country_runtime.h');s=p.read_text();needle='    godot::Dictionary cell_summary(int32_t cell) const;';s=s.replace(needle,'    // Main-thread presentation replica only; never installed into the authority.\n    void apply_committed_read_snapshot(const RuntimeCountryPodSnapshot &snapshot);\n\n'+needle);p.write_text(s)
p=Path('gdext/src/world_ext.h');s=p.read_text();s=s.replace('class NativeSimulationHost;','class NativeSimulationHost;\nclass NativeCountryRuntime;',1);needle='    void                                     *_country_runtime        = nullptr;';s=s.replace(needle,needle+'\n    NativeCountryRuntime *country_query_runtime() const;\n    mutable void *_country_query_runtime = nullptr;\n    mutable std::shared_ptr<const RuntimeCountryPodSnapshot> _country_query_snapshot;');p.write_text(s)
p=Path('gdext/src/world_ext.cpp');s=p.read_text();needle='    if (_country_runtime != nullptr) {\n        delete static_cast<NativeCountryRuntime *>(_country_runtime);';s=s.replace(needle,'    if (_country_query_runtime != nullptr) {\n        delete static_cast<NativeCountryRuntime *>(_country_query_runtime);\n        _country_query_runtime = nullptr;\n    }\n'+needle);p.write_text(s)
p=Path('gdext/src/world_ext_country.cpp');s=p.read_text();a=s.index('Dictionary DCWorldExt::get_country_cell_summary');b=s.index('Dictionary DCWorldExt::poll_country_events',a);chunk=s[a:b].replace('country_runtime_from(_country_runtime)', 'country_query_runtime()');s=s[:a]+chunk+s[b:];a=s.index('Dictionary DCWorldExt::get_country_cell_summary');method='''NativeCountryRuntime *DCWorldExt::country_query_runtime() const {
    auto *source = country_runtime_from(_country_runtime);
    if (source == nullptr || _runtime_host == nullptr ||
        !_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY))
        return source;
    const auto snapshot = _runtime_host->country_asset_snapshot();
    if (!snapshot) return source;
    if (_country_query_runtime == nullptr)
        _country_query_runtime = new NativeCountryRuntime(*source);
    auto *view = country_runtime_from(_country_query_runtime);
    if (_country_query_snapshot != snapshot) {
        view->apply_committed_read_snapshot(*snapshot);
        _country_query_snapshot = snapshot;
    }
    return view;
}

''';s=s[:a]+method+s[a:];# reset cache when catalog reconfigured
needle='    if (_country_runtime == nullptr) _country_runtime = new NativeCountryRuntime();';s=s.replace(needle,'    delete country_runtime_from(_country_query_runtime);\n    _country_query_runtime = nullptr;\n    _country_query_snapshot.reset();\n'+needle,1);p.write_text(s)
p=Path('gdext/src/country_runtime.cpp');s=p.read_text();a=s.index('Dictionary NativeCountryRuntime::cell_summary');export=s[s.index('bool NativeCountryRuntime::export_pod_snapshot'):s.index('bool NativeCountryRuntime::export_pod_catalog')];import re
pairs=re.findall(r'    out\.(\w+) = (_\w+(?:\.\w+)?);',export)
exclude={'catalog_hash','research_active_index_valid'}
lines=['void NativeCountryRuntime::apply_committed_read_snapshot(', '        const RuntimeCountryPodSnapshot &snapshot) {','    _simulation_host = nullptr;','    _sync_store_writes_forbidden = true;','    _state_hash_cache_valid = false;']
for key,target in pairs:
 if key not in exclude: lines.append(f'    {target} = snapshot.{key};')
lines+=['    _tax_policy_version = snapshot.generation;', '    _territory_generation = snapshot.generation;', '    _research_generation = snapshot.generation;', '    _visual_era_generation = snapshot.generation;', '    _country_research_progress.assign(snapshot.country_count, {});', '    _country_research_signal_cells.assign(snapshot.country_count, {});', '    _country_research_signal_evidence.assign(snapshot.country_count, {});', '    for (uint32_t slot = 0; slot < snapshot.country_count; ++slot) {', '        for (uint32_t tech = 0; tech < snapshot.technology_count; ++tech) {', '            const auto value = snapshot.research_progress[slot * snapshot.technology_count + tech];', '            if (value != 0) _country_research_progress[slot].emplace_back(tech, value);', '        }', '        _country_research_signal_cells[slot].assign(', '            snapshot.research_signal_cells.begin() + snapshot.research_signal_cell_offsets[slot],', '            snapshot.research_signal_cells.begin() + snapshot.research_signal_cell_offsets[slot + 1]);', '        for (int32_t i = snapshot.research_signal_evidence_offsets[slot];', '             i < snapshot.research_signal_evidence_offsets[slot + 1]; ++i) {', '            const auto &v = snapshot.research_signal_evidence[i];', '            _country_research_signal_evidence[slot].push_back(', '                {v.signal, v.count, v.first_day, v.last_day, v.first_cell});', '        }', '    }', '    _cell_tax_policies.clear();', '    for (const auto &policy : snapshot.cell_tax_policies) {', '        CellTaxPolicy out;', '        out.defaults = policy.defaults;', '        out.default_modes = policy.modes;', '        for (const auto &v : policy.overrides)', '            out.overrides.push_back({v.kind, v.item, v.rate, v.mode});', '        _cell_tax_policies.push_back(std::move(out));', '    }', '    _report = _report.duplicate();', '    _report["last_committed_day"] = snapshot.committed_day;', '}','']
s=s[:a]+'\n'.join(lines)+'\n'+s[a:];p.write_text(s)
