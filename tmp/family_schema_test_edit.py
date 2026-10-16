from pathlib import Path
p=Path('Project/project-keynes/tests/family_runtime_test.gd'); s=p.read_text(encoding='utf-8').replace('PKEC v55 save begins','PKEC v56 save begins'); p.write_text(s,encoding='utf-8')
