from pathlib import Path
s=Path('tmp/edit_worker_timing.py').read_text(encoding='utf-8')
init=s[:s.index("edit('gdext/src/native_simulation_host.h'")]
tail=s[s.index('def bridge(s):'):]
tail=tail.replace('void DCWorldExt::profile_runtime_save_window','void pk::DCWorldExt::profile_runtime_save_window')
exec(init+tail)
