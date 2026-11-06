#!/usr/bin/env python3
"""Enforce Country/Economy adapter ownership at the existing provider boundary."""
from pathlib import Path
import argparse
import re
ROOT=Path(__file__).resolve().parents[2]
BASE='Project/project-keynes/scripts/game/'
from check_save_section_contracts import violations as cpp_section_violations

def violations(root):
    errors=[]
    specs=[('country_state.gd','pkcn',('capture_ecp2','restore_ecp2','native_economy_ecp2'), 'simulation_runtime'),
           ('economy_state.gd','ecp2',('restore_country_runtime_checkpoint','native_country_pkcn'), 'pkcn')]
    for filename, section, forbidden, dependency in specs:
        text=(root/(BASE+'save_modules/'+filename)).read_text()
        code=re.sub(r'#.*','',text)
        # Dependency names in archive_contract are metadata, not byte access.
        implementation = code[code.find("\nfunc "):]
        foreign_section = 'ecp2' if filename == 'country_state.gd' else 'pkcn'
        if re.search(r'\b' + foreign_section + r'\b', implementation):
            errors.append(filename+' foreign section byte access '+foreign_section)
        for token in forbidden:
            if re.search(r'\b'+token+r'\b',code): errors.append(filename+' foreign archive access '+token)
        if filename=='economy_state.gd' and re.search(r'context\s*(?:\.\s*country\b|\[\s*["\x27]country["\x27])',code):
            errors.append(filename+' foreign owner capability')
        for token in ('archive_contract','"id"','"version"','"sections"','"restore_after"','"readable_versions"','"write"','"restore"'):
            if token not in code: errors.append(filename+' missing contract '+token)
        if '"'+section+'"' not in code or '"'+dependency+'"' not in code:
            errors.append(filename+' contract identity/dependency missing')
    composition=(root/(BASE+'world_state_modules.gd')).read_text()
    for owner in ('CountryState','EconomyState'):
        if '_owned_provider(adapters[' not in composition or owner+'.archive_contract(' not in composition:
            errors.append('composition bypasses '+owner+' contract')
    if (root / "tools/ci/cpp_save_section_contracts.json").exists():
        errors.extend(cpp_section_violations(root))
    return errors

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=ROOT);a=p.parse_args()
    errors=violations(a.root)
    for e in errors:print(e)
    print(f'save contracts: 2 script owners + 12 C++ domains, {len(errors)} violations')
    return bool(errors)
if __name__=='__main__':raise SystemExit(main())
