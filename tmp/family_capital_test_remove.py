from pathlib import Path
p=Path('Project/project-keynes/tests/family_split_choice_runtime_test.gd'); s=p.read_text(encoding='utf-8').replace('\t_test_capital_does_not_replace_departed_founder(catalog)\n',''); a=s.index('func _test_capital_does_not_replace_departed_founder('); b=s.index('func _new_ext(',a); s=s[:a]+s[b:]; p.write_text(s,encoding='utf-8')
