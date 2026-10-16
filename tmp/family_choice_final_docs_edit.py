from pathlib import Path
p=Path('docs/cpp-dots-runtime/notable-family-runtime.md')
s=p.read_text(encoding='utf-8')
s=s.replace('bootstrap 不触发。若旧会话已在无家族状态下运行，日常 `FAMILY_COMMIT` 会在第 0..30 天检查\n上述权威不变量，并在 owner 岗确已占满时补建一次；权威 membership 边防止同批次重复创建。','bootstrap 不触发。v56 取消日常 FAMILY_COMMIT 的 0..30 天补建入口：原首都家族迁走或消亡后，\n后续家族必须走正常扶持，不再静默创建替代 Starter。开局 v2/v3 bootstrap 兼容仍保留。')
s=s.replace('当前 writer 为 PKEC v56，并显式兼容读取 v55；以上 v41/v55 章节保留历史格式说明。','当前 writer 为 PKEC v56，并显式兼容读取 v55；以上 v41/v55 章节保留历史格式说明。\n开局创始家族只由 bootstrap 创建，已取消日常首都补建，以免原家族迁出或消亡后跳过扶持再造新族。')
p.write_text(s,encoding='utf-8')
for name in ['.agents/skills/project-keynes-family-runtime/SKILL.md','.codex/skills/project-keynes-family-runtime/SKILL.md']:
 p=Path(name); s=p.read_text(encoding='utf-8'); s=s.replace('Repair an empty forced capital only\nduring days 0..30 and only after its exact owner posts are occupied; use authoritative membership edges\nfor idempotence and let the normal PERSON_COMMIT promotion path create and bind the representative.','Opening creation belongs to bootstrap only. Do not repair an empty capital during daily commit:\na starter may have migrated or dissolved, so a replacement must follow the ordinary player choice gate.')
 p.write_text(s,encoding='utf-8')
p=Path('Project/project-keynes/tests/family_split_choice_runtime_test.gd'); s=p.read_text(encoding='utf-8').replace('_test_newly_claimed_player_cell','_test_newly_acquired_player_cell').replace('claim fixture pauses','territory fixture pauses'); p.write_text(s,encoding='utf-8')
