from pathlib import Path
p=Path('gdext/src/economy_runtime.cpp'); s=p.read_text(encoding='utf-8'); a=s.index('void NativeEconomyRuntime::reunite_split_family_branches()'); b=s.index('void NativeEconomyRuntime::split_family_branches()',a); s=s[:a]+s[b:]; s=s.replace('    reunite_split_family_branches();\n',''); p.write_text(s,encoding='utf-8')
p=Path('gdext/SConstruct'); s=p.read_text(encoding='utf-8').replace('dots_ext_family_choice_v56_r2','dots_ext_family_choice_v56_r3'); p.write_text(s,encoding='utf-8')
p=Path('docs/cpp-dots-runtime/notable-family-runtime.md'); s=p.read_text(encoding='utf-8'); old='''`_family_split_parents` 保存按子族 stable_id 排序的真实母子稳定 ID 对。母族后续迁入
子族起源格时，FAMILY_COMMIT 将该当地分支并入已独立的子族，避免反复产生同宗编号家族；
仅改归属，人口、现金、商品、建筑与人物总量守恒。操作沿用 family/member/ownership/person CSR。
无关同姓家族不按姓氏合并。旧档未记录母子关联的历史家族不猜测亲缘，也不批量合并。'''; new='''`_family_split_parents` 仅保存按子族 stable_id 排序的真实母子稳定 ID 对，不参与迁入归属。
A 在乙地的分支独立为 A1 后，后续从 A 迁入乙地的成员仍属于 A；乙地可同时有 A 与 A1。
这批 A 成员达到分家条件时，再独立进入三选一，不并入 A1，也不覆盖 A1 的身份或家风。
同姓或母子关系均不触发自动合并。旧档中的 lineage 继续读取和保存，存档格式及哈希规则不变。'''; assert old in s; s=s.replace(old,new).replace('后续母族迁入归并','后续母族迁入保持身份、母子同格共存'); p.write_text(s,encoding='utf-8')
for name in ['.agents/skills/project-keynes-family-runtime/SKILL.md','.codex/skills/project-keynes-family-runtime/SKILL.md']:
 p=Path(name); s=p.read_text(encoding='utf-8'); old='''explicit v55 decoding supplies zero/empty fields without inventing historical lineage. Later arrivals
from the recorded parent join the local child; never merge unrelated families by surname.'''; new='''explicit v55 decoding supplies zero/empty fields without inventing historical lineage. Later arrivals
from the parent retain the parent's identity. Parent A and independent child A1 may coexist in the same
cell; later A arrivals may independently qualify for another player-reviewed split. Lineage is metadata
only and never routes migration or merges families, including related houses sharing a surname.'''; assert old in s; s=s.replace(old,new); p.write_text(s,encoding='utf-8')
