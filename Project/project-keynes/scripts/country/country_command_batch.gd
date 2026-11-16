extends RefCounted

## Value-only command packing. CountryFacade retains configuration and submission.
static func pack(commands: Array[Dictionary], preserve_effective_days: bool,
		default_tax_mode: int) -> Dictionary:
	var batch := {
		"preserve_effective_days": preserve_effective_days,
		"opcodes": PackedInt32Array(),
		"effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(),
		"target_handles": PackedInt64Array(),
		"cell_indices": PackedInt32Array(),
		"aux_i32": PackedInt32Array(),
		"domain_i32": PackedInt32Array(),
		"position_i32": PackedInt32Array(),
		"weight0_bp": PackedInt32Array(),
		"weight1_bp": PackedInt32Array(),
		"weight2_bp": PackedInt32Array(),
		"weight3_bp": PackedInt32Array(),
		"value_i64": PackedInt64Array(),
		"tax_kinds": PackedInt32Array(),
		"tax_item_indices": PackedInt32Array(),
		"tax_rate_basis_points": PackedInt32Array(),
		"tax_assessment_modes": PackedInt32Array(),
		"stable_ids": PackedStringArray(),
		"display_names": PackedStringArray(),
	}
	for command in commands:
		batch.opcodes.append(int(command.get("opcode", 0)))
		batch.effective_days.append(int(command.get("effective_day", 0)))
		batch.sequences.append(int(command.get("sequence", 0)))
		batch.target_handles.append(int(command.get("target_handle", 0)))
		batch.cell_indices.append(int(command.get("cell", -1)))
		batch.aux_i32.append(int(command.get("signal", command.get("technology", -1))))
		batch.domain_i32.append(int(command.get("domain", -1)))
		batch.position_i32.append(int(command.get("position", -1)))
		var weights: PackedInt32Array = command.get("weights_bp",
			PackedInt32Array([0, 0, 0, 0]))
		for domain in range(4):
			batch["weight%d_bp" % domain].append(
				int(weights[domain]) if domain < weights.size() else 0)
		batch.value_i64.append(int(command.get("value", 0)))
		batch.tax_kinds.append(int(command.get("tax_kind", -1)))
		batch.tax_item_indices.append(int(command.get("tax_item", -1)))
		batch.tax_rate_basis_points.append(int(command.get(
			"tax_rate_basis_points",
			int(command.get("tax_rate_percent", 0)) * 100)))
		batch.tax_assessment_modes.append(int(command.get(
			"tax_assessment_mode", default_tax_mode)))
		batch.stable_ids.append(String(command.get("stable_id", "")))
		batch.display_names.append(String(command.get("display_name", "")))
	return batch
