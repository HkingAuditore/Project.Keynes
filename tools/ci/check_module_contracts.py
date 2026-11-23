#!/usr/bin/env python3
"""Check module metadata and the reviewed committed-read consumer surfaces."""
from pathlib import Path
import argparse
import json
import re
from check_cpp_deps import code_only
ROOT = Path(__file__).resolve().parents[2]
REGISTRY = 'tools/ci/runtime_module_contracts.json'
HEADER = 'gdext/src/runtime_module_contracts.h'
FREEZE_READS = {
    'climate': 'gdext/src/native_simulation_stage_climate.cpp',
    'country': 'gdext/src/native_simulation_stage_country.cpp',
    'economy': 'gdext/src/native_simulation_stage_economy.cpp',
}

def freeze_read_violations(root):
    errors = []
    for module, source in FREEZE_READS.items():
        path = root / source
        # Small isolated guard fixtures may only copy the registry/header; the
        # full repository is still required to contain every production file.
        if not path.exists():
            continue
        code = code_only(path.read_text())
        token = 'freeze_reads.register_read'
        if token not in code or f'RuntimeDomainId::{module.upper()}' not in code:
            errors.append(f'{module} missing frozen input registration')
    return errors

def render(data):
    lines = ['#pragma once', '#include "runtime_pod_protocol.h"', '', 'namespace pk {',
             'struct RuntimeModuleContract {', '    const char *id;', '    RuntimeDomainId domain;',
             '    const char *cadence;', '    const char *reads;', '    const char *store;',
             '    const char *intent_types;', '    uint32_t view_version;', '    const char *save_sections;',
             '};', 'inline constexpr RuntimeModuleContract runtime_module_contracts[] = {']
    for m in data['modules']:
        q = lambda key: json.dumps(m[key])
        lines.append('    {' + ', '.join([q('id'), 'RuntimeDomainId::'+m['domain'], q('cadence'),q('reads'),q('store'),q('intent_types'),str(m['view_version']),q('save_sections')]) + '},')
    return '\n'.join(lines + ['};', '} // namespace pk', ''])

def stage_order_violations(data):
    modules = {m['id']: i for i, m in enumerate(data['modules'])}
    allowed = {
        (item['module'], item['owner'])
        for item in data.get('known_order_debts', [])
    }
    errors = []
    for module in data['modules']:
        index = modules[module['id']]
        for owner in (part.strip() for part in module['reads'].split(',')):
            if owner not in modules or modules[owner] < index:
                continue
            pair = (module['id'], owner)
            if pair not in allowed:
                errors.append(
                    f"stage order: {module['id']} reads {owner} at or after its stage")
    return errors

def violations(root, data):
    errors = []
    if (root / HEADER).read_text() != render(data): errors.append('generated module contracts differ')
    modules = {m['id']: m for m in data['modules']}
    if len(modules) != 12: errors.append('expected twelve distinct modules')
    modules.update({m['id']: m for m in data.get('consumers', [])})
    errors.extend(freeze_read_violations(root))
    errors.extend(stage_order_violations(data))
    # Known read APIs on these surfaces must have a registration; unknown APIs
    # still require the committed-view guard and code review.
    apis = {x['call'] for x in data['reviewed_reads']}
    by_source = {}
    for edge in data['reviewed_reads']:
        by_source.setdefault(edge['source'], set()).add(edge['call'])
        m = modules[edge['module']]
        if edge['owner'] not in [v.strip() for v in m['reads'].split(',')]:
            errors.append(edge['module']+' undeclared read of '+edge['owner'])
        if not re.search(r'\b'+edge['call']+r'\s*\(', code_only((root/edge['source']).read_text())):
            errors.append('declared read missing: '+edge['source']+' '+edge['call'])
    for source, allowed in by_source.items():
        code = code_only((root/source).read_text())
        for call in apis - allowed:
            if re.search(r'\b'+call+r'\s*\(', code): errors.append(source+' unregistered read '+call)
    return errors

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=ROOT);p.add_argument('--write-header',action='store_true');a=p.parse_args()
    data=json.loads((a.root/REGISTRY).read_text())
    if a.write_header: (a.root/HEADER).write_text(render(data))
    errors=violations(a.root,data)
    for e in errors: print(e)
    print(f'module contracts: {len(data["modules"])} modules, {len(data["reviewed_reads"])} reviewed reads, {len(errors)} violations')
    return bool(errors)
if __name__=='__main__': raise SystemExit(main())
