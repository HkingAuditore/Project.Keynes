from pathlib import Path
src=Path('Project/project-keynes/tests/family_founding_offer_runtime_test.gd').read_text(encoding='utf-8')
p=Path('Project/project-keynes/tests/family_split_choice_runtime_test.gd')
s=p.read_text(encoding='utf-8')
methods=src[src.index('func _new_ext('):src.index('func _run_day(')]
methods=methods.replace('ext.create_entities(1)','ext.create_entities(2)').replace('PackedFloat32Array([0.5])','PackedFloat32Array([0.5, 0.5])').replace('PackedByteArray([0])','PackedByteArray([0, 0])').replace('PackedFloat32Array([1000000.0])','PackedFloat32Array([1000000.0, 1000000.0])').replace('PackedFloat32Array([0.0])','PackedFloat32Array([0.0, 0.0])').replace('}, 1, seed)','}, 2, seed)').replace('PackedInt32Array([0, 1])','PackedInt32Array([0, 2])').replace('"territory_cells": PackedInt32Array([0])','"territory_cells": PackedInt32Array([0, 1])')
p.write_text(s+'\n'+methods,encoding='utf-8')
