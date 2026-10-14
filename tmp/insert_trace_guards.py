import re

targets = {
    'gdext/src/world_ext_climate.cpp': [
        'run_climate_pass_a', 'run_runtime_hydrology_pass',
        'run_climate_feedback_pass', 'run_stage_b_pass'],
    'gdext/src/world_ext_generate.cpp': ['run_season_refresh_stage'],
    'gdext/src/world_ext.cpp': ['refresh_slots_from_map', 'refresh_slots_from_map_keys'],
    'gdext/src/world_ext_simulation_host.cpp': [
        'apply_runtime_climate_writeback', 'capture_runtime_inputs'],
}
MARK = 'SimTraceWriteGuard sim_trace_guard{this, "'
for path, funcs in targets.items():
    raw = open(path, 'rb').read().decode('utf-8')
    nl = '\r\n' if '\r\n' in raw else '\n'
    lines = raw.split(nl)
    for fn in funcs:
        pat = re.compile(r'^[A-Za-z].*DCWorldExt::' + fn + r'\(')
        idx = next(i for i, l in enumerate(lines) if pat.match(l))
        j = idx
        while not lines[j].rstrip().endswith('{'):
            j += 1
        if MARK in lines[j + 1]:
            continue
        lines.insert(j + 1, '    ' + MARK + fn + '"};')
        print(path, fn, 'line', j + 2)
    open(path, 'wb').write(nl.join(lines).encode('utf-8'))
