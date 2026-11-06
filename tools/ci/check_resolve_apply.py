#!/usr/bin/env python3
"""Reviewed Resolve admission and Apply access sets; lexical, not C++ alias analysis."""
import argparse, json, re
from pathlib import Path
from check_cpp_deps import code_only
ROOT=Path(__file__).resolve().parents[2]
REGISTRY="tools/ci/resolve_apply_contracts.json"
def body(source, signature):
    code=code_only(source); start=code.find(signature)
    if start < 0: return None
    start=code.find("{", start); depth=1; end=start+1
    while depth and end<len(code):
        depth += (code[end]=="{")-(code[end]=="}"); end+=1
    return code[start:end] if depth==0 else None

def access_set(code):
    # Include every owner member access, even reads, to catch writes hidden in
    # a new alias or member pointer. Existing aliases remain a review boundary.
    return sorted(set(re.findall(r"\b_[a-zA-Z]\w*", code)))

def stage_writes(root):
    source=(root/'gdext/src/native_simulation_host.cpp').read_text()
    return dict(re.findall(r'\{"(\w+)", RuntimeDomainId::\w+, &NativeSimulationHost::\w+,\s*"[^"]*", "([^"]*)", false,',source))

def soft_reasons(root, row):
    source=(root/row['source']).read_text()
    match=re.search(r'const bool '+row['condition']+r'\s*=([\s\S]*?);',source)
    return re.findall(r'"([^"]+)"',match[1]) if match else None

def queue_surfaces(root):
    rows=[]
    for path in sorted((root/'gdext/src').glob('*.cpp')):
        for match in re.finditer(r'^\s*(?:bool|void|Dictionary)\s+(\w+::(?:queue_command|submit_\w*command|enqueue_\w+))\s*\(', code_only(path.read_text()), re.M):
            rows.append(path.relative_to(root).as_posix()+'|'+match[1])
    return rows

def violations(root, data):
    errors=[]
    for entry in set(queue_surfaces(root))-set(data.get('registered_entrypoints',{})):
        errors.append('unregistered request entry '+entry)
    if stage_writes(root) != data.get('stage_writes'):
        errors.append('stage writes declaration differs from reviewed set')
    for row in data.get('retained_soft_paths',[]):
        if soft_reasons(root,row)!=row['reasons']:
            errors.append('unregistered soft-completion reason '+row['source'])
    for row in data['resolve']:
        path=root/row['source']; code=body(path.read_text(),row['function']) if path.exists() else None
        if code is None: errors.append('missing Resolve surface '+row['source']); continue
        if row['entry'] not in code: errors.append('Resolve admission bypass '+row['source'])
        for forbidden in row['bypass']:
            if re.search(forbidden,code): errors.append('raw queue bypass '+row['source'])
    for row in data['apply']:
        path=root/row['source']; code=body(path.read_text(),row['function']) if path.exists() else None
        if code is None: errors.append('missing Apply surface '+row['source']); continue
        for member in set(access_set(code))-set(row['allowed_members']):
            errors.append('Apply outside declared set '+row['source']+': '+member)
        for member in row.get('readonly_members',[]):
            if re.search(r'\b'+re.escape(member)+r'\b[^;\n]*(?:(?<![=!<>])=(?!=)|\+\+|--|\.(?:clear|erase|push_back|assign|swap)\s*\()',code):
                errors.append('Apply writes read-only input '+member)
        for peer in row['forbidden_peer_mutations']:
            if re.search(r'\b'+peer+r'\b',code): errors.append('Apply foreign mutation '+peer)
        if not row['writes'] or not row['scope']: errors.append('Apply ownership undocumented')
    return errors

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=ROOT);a=p.parse_args()
    d=json.loads((a.root/REGISTRY).read_text()); errors=violations(a.root,d)
    for e in errors: print(e)
    print(f"Resolve/Apply: {len(d['resolve'])} queues, {len(d['apply'])} Apply surfaces, {len(errors)} violations")
    return bool(errors)
if __name__=='__main__': raise SystemExit(main())
