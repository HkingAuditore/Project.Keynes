from pathlib import Path
p=Path('gdext/src/economy_runtime.cpp'); s=p.read_text(encoding='utf-8'); a=s.index('bool NativeEconomyRuntime::repair_forced_capital_founder('); b=s.index('bool NativeEconomyRuntime::build_family_split_offer(',a); s=s[:a]+s[b:]; p.write_text(s,encoding='utf-8')
p=Path('gdext/src/economy_runtime.h'); s=p.read_text(encoding='utf-8'); s='\n'.join(line for line in s.split('\n') if 'bool repair_forced_capital_founder(' not in line); p.write_text(s,encoding='utf-8')
p=Path('gdext/SConstruct'); s=p.read_text(encoding='utf-8').replace('dots_ext_family_choice_v56_r1','dots_ext_family_choice_v56_r2'); p.write_text(s,encoding='utf-8')
