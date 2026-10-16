from pathlib import Path
section='''
## 分支立族与领土交互边界（2026-10-17，PKEC v56）

当前 writer 为 PKEC v56，并显式兼容读取 v55；以上 v41/v55 章节保留历史格式说明。

玩家异地分支达到 100 人时先生成三套家风／效果方案。每套保留母族姓氏，沿用原来的
去一增一至二及特效分家策略，提前冻结 stable_id、特性和随机池效果。确认前整支仍属于母族；
确认后本地全部 membership、cash claim、建筑 ownership 和重要人物统一转入所选子族，
母族在其他城市继续存在。未选方案不创建家族，不吸收匿名人口或建筑，不推进普通立族里程碑。

`FamilyFoundingOffer.source_family_handle=0` 表示普通立族，非零表示分家。查询附加
`kind=FOUNDING/SPLIT` 与源家族句柄。两者复用同格至多一组的队列、generation 检查、
SELECTED_PENDING、时钟锁、地图定位与六次失败作废机制。UI 以「分支立族／择定家风」
提醒玩家，展示分支人数、家风、效果及整支转移范围。AI 与显式 AUTO 仍自动选择。

玩家选择门同时尊重日初冻结归属和 Country 当前已提交归属，避免周期开始后转归玩家的
地块按原外国／无主归属自动立族。该读取只控制交互资格；经济、科技和税务输入继续冻结。

`_family_split_parents` 保存按子族 stable_id 排序的真实母子稳定 ID 对。母族后续迁入
子族起源格时，FAMILY_COMMIT 将该当地分支并入已独立的子族，避免反复产生同宗编号家族；
仅改归属，人口、现金、商品、建筑与人物总量守恒。操作沿用 family/member/ownership/person CSR。
无关同姓家族不按姓氏合并。旧档未记录母子关联的历史家族不猜测亲缘，也不批量合并。

section 35 kind 0 追加 lineage 计数；kind 2 在 failed_reviews 后追加
`u64 source_family_handle`；kind 5 保存 `(i64 child_stable_id, i64 parent_stable_id)`。
v55 显式解码补零源句柄与空 lineage，不补抽家风、效果或历史母子关系；普通待决卡组保留
原哈希。v56 待决分家与完成 lineage 均参与 state hash，支持完整 round-trip。其他旧版本
拒绝规则保持原状。ECP2 外层格式不变，内层 PKEC 按对应版本解码。

回归入口 `tests/family_split_choice_runtime_test.gd`：真实人口迁入、等待不自动分家、同姓
三套方案、选择后整支替换与母族保留、冻结特性兑现、后续母族迁入归并、待决／完成存读档哈希、
EPOCH_BEGIN 后转归玩家地块的普通立族等待扶持。`family_founding_dialog_ui_test.gd` 覆盖
分家提示、分支人数与专用选择文案。
'''
p=Path('docs/cpp-dots-runtime/notable-family-runtime.md'); p.write_text(p.read_text(encoding='utf-8').rstrip()+'\n'+section,encoding='utf-8')
p=Path('docs/cpp-dots-runtime/economy-save-migration-sop.md'); p.write_text(p.read_text(encoding='utf-8').rstrip()+'''\n\n## PKEC v56 家族分支选择（2026-10-17）

writer=56；reader 显式接受 55/56。v55 -> v56 只补空的分家来源与母子关联，不改变原有家族、
候选身份和普通待决卡组哈希。section 35 的扩展、交互语义与回归入口见
[家族运行时：分支立族与领土交互边界](notable-family-runtime.md#分支立族与领土交互边界2026-10-17pkec-v56)。
实际 v55 DLL 写出的含待决卡组存档已用 v56 reader 验证恢复和 state hash 一致。
''',encoding='utf-8')
for name in ['.agents/skills/project-keynes-family-runtime/SKILL.md','.codex/skills/project-keynes-family-runtime/SKILL.md']:
 p=Path(name)
 p.write_text(p.read_text(encoding='utf-8').rstrip()+'''\n\n## Player-reviewed branch splits (2026-10-17)

Player-owned off-origin branches do not split silently. Freeze three surname-preserving trait/effect
proposals in the existing FamilyFoundingOffer queue, wait for the player's choice, then transfer the
whole local membership, cash attribution, ownership and people to the selected child. Keep the parent
elsewhere. Persist the source generation-safe handle and child/parent stable-ID lineage in PKEC v56;
explicit v55 decoding supplies zero/empty fields without inventing historical lineage. Later arrivals
from the recorded parent join the local child; never merge unrelated families by surname.
Only the choice gate may consult committed Country ownership in addition to the frozen epoch, so
territory acquired mid-epoch cannot automatically found a player family. Economic inputs stay frozen.
Validate family_split_choice_runtime_test.gd and family_founding_dialog_ui_test.gd, conservation,
pending/resolved save hashes, and v55 compatibility. See the authoritative notable-family-runtime.md.
''',encoding='utf-8')
