from pathlib import Path
p=Path('Project/project-keynes/tests/family_split_choice_runtime_test.gd')
s=p.read_text(encoding='utf-8')
a=s.index('\tvar ext := _split_world(catalog)',s.index('func _test_split_choice(')); b=s.index('\tvar initial:',a)
boot=s[a:b].replace('\tvar ext := _split_world(catalog)','\t_fixture_cells = 2\n\tvar ext := _split_world(catalog)').replace('"cell_indices": PackedInt32Array([0, 0]),','"forced_named_cells": PackedInt32Array([0]),\n\t\t"cell_indices": PackedInt32Array([0, 0]),')
new='''
func _test_capital_does_not_replace_departed_founder(catalog: Dictionary) -> void:
'''+boot+'''
    var source: Dictionary = ext.get_population_cell_snapshot(0)
    var signatures: PackedInt32Array = source.signature_ids
    var owner_index := signatures.find(owner)
    var merchant_index := signatures.find(merchant)
    var queued: Dictionary = ext.submit_economy_commands({
        "opcodes": PackedInt32Array([7, 8]), "effective_days": PackedInt64Array([0, 0]),
        "sequences": PackedInt64Array([80, 81]),
        "target_handles": PackedInt64Array([int(source.handles[owner_index]), int(source.handles[merchant_index])]),
        "i32_0": PackedInt32Array([1, owner]), "i32_1": PackedInt32Array([0, 0]),
        "i64_0": PackedInt64Array([600, 40]), "i64_1": PackedInt64Array([0, 0]),
    })
    _expect("capital evacuation and anonymous replacement operators queue", bool(queued.get("ok", false)))
    var report := _run_day(ext, 0)
    var capital: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
    _expect("empty original capital does not silently generate another starter", _conserved(report)
        and int(capital.get("total", -1)) == 0)
    var buildings: Dictionary = ext.get_building_cell_snapshot(0)
    var owner_fills: PackedInt64Array = buildings.get("filled_owner", PackedInt64Array())
    _expect("capital still has occupied owner posts so the former repair path was eligible",
        not owner_fills.is_empty() and int(owner_fills[0]) > 0)
'''.replace('    ','\t')
s=s.replace('func _new_ext(catalog: Dictionary) -> Object:',new+'\nfunc _new_ext(catalog: Dictionary) -> Object:')
p.write_text(s,encoding='utf-8')
