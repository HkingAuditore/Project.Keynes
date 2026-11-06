extends RefCounted

## Dispatch facade for split world_runtime_gm_adapter.gd.

var _part1 = preload("res://scripts/game/world_runtime_gm_adapter_part1.gd").new()
var _part2 = preload("res://scripts/game/world_runtime_gm_adapter_part2.gd").new()

func dump_render_profile(host) -> Dictionary:
	return await _part1.dump_render_profile(host)
func set_perf_recorder(host, recorder: RefCounted) -> void:
	_part1.set_perf_recorder(host, recorder)
func get_perf_recorder(host) -> RefCounted:
	return _part1.get_perf_recorder(host)
func set_tile_data_recorder(host, recorder: RefCounted) -> void:
	_part1.set_tile_data_recorder(host, recorder)
func get_tile_data_recorder(host) -> RefCounted:
	return _part1.get_tile_data_recorder(host)
func set_economy_data_recorder(host, recorder: RefCounted) -> void:
	_part1.set_economy_data_recorder(host, recorder)
func get_economy_data_recorder(host) -> RefCounted:
	return _part1.get_economy_data_recorder(host)
func get_gm_capabilities(host) -> Dictionary:
	return _part1.get_gm_capabilities(host)
func get_gm_snapshot(host, section: String, _context: Dictionary = {}) -> Dictionary:
	return _part1.get_gm_snapshot(host, section, _context)
func execute_gm_command(host, command_id: String, raw_args: Dictionary) -> Dictionary:
	return _part1.execute_gm_command(host, command_id, raw_args)
func get_gm_toggle_state(host, toggle_id: String) -> Dictionary:
	return _part1.get_gm_toggle_state(host, toggle_id)
func set_gm_toggle(host, toggle_id: String, enabled: bool) -> Dictionary:
	return _part1.set_gm_toggle(host, toggle_id, enabled)
func _gm_command_specs(host, technologies: PackedStringArray = PackedStringArray(),
		goods: PackedStringArray = PackedStringArray(),
		buildings: PackedStringArray = PackedStringArray()) -> Array:
	return _part1._gm_command_specs(host, technologies, goods, buildings)
func _gm_overview_snapshot(host) -> Dictionary:
	return _part1._gm_overview_snapshot(host)
func _poll_runtime_health(host) -> void:
	_part1._poll_runtime_health(host)
func _observe_economy_fatal(host, report: Dictionary) -> void:
	_part1._observe_economy_fatal(host, report)
func _poll_simulation_stall_watchdog(host) -> void:
	_part1._poll_simulation_stall_watchdog(host)
func _web_barrier_diag(host) -> Dictionary:
	return _part1._web_barrier_diag(host)

func _gm_selected_snapshot(host, cell_idx: int) -> Dictionary:
	return _part2._gm_selected_snapshot(host, cell_idx)
func _gm_resource_snapshot(host, cell_idx: int) -> Array:
	return _part2._gm_resource_snapshot(host, cell_idx)
func _gm_recorder_snapshot(host) -> Dictionary:
	return _part2._gm_recorder_snapshot(host)
func _gm_one_recorder_state(host, recorder: RefCounted) -> Dictionary:
	return _part2._gm_one_recorder_state(host, recorder)
func _gm_execute_country_command(host, command_id: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	return _part2._gm_execute_country_command(host, command_id, args, effective_day, sequence)
func _gm_execute_economy_command(host, command_id: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	return _part2._gm_execute_economy_command(host, command_id, args, effective_day, sequence)
func _gm_validate_args(host, spec: Dictionary, raw_args: Dictionary) -> Dictionary:
	return _part2._gm_validate_args(host, spec, raw_args)
func _gm_convert_arg(host, value, spec: Dictionary) -> Dictionary:
	return _part2._gm_convert_arg(host, value, spec)
func _gm_find_command_spec(host, command_id: String) -> Dictionary:
	return _part2._gm_find_command_spec(host, command_id)
func _gm_resolve_cell(host, args: Dictionary) -> int:
	return _part2._gm_resolve_cell(host, args)
func _gm_selected_country_handle(host) -> int:
	return _part2._gm_selected_country_handle(host)
func _gm_set_click_claim_territory_enabled(host, enabled: bool) -> Dictionary:
	return _part2._gm_set_click_claim_territory_enabled(host, enabled)
func _gm_claim_selected_cell(host, cell: HexCell) -> void:
	_part2._gm_claim_selected_cell(host, cell)
func _gm_emit_claim_result(host, raw_result: Dictionary, cell_idx: int) -> void:
	_part2._gm_emit_claim_result(host, raw_result, cell_idx)
func _gm_scaled_positive(host, value, scale: int) -> int:
	return _part2._gm_scaled_positive(host, value, scale)
func _gm_renderer_toggle_state(host, property_name: String) -> Dictionary:
	return _part2._gm_renderer_toggle_state(host, property_name)
func _print_terrain_material_gate_state(host) -> void:
	_part2._print_terrain_material_gate_state(host)
func _print_cell_index_view_state(host) -> void:
	_part2._print_cell_index_view_state(host)
func _print_enum_lut_view_state(host) -> void:
	_part2._print_enum_lut_view_state(host)
func _print_river_flow_state(host) -> void:
	_part2._print_river_flow_state(host)
func dump_flow_tex_report(host) -> Dictionary:
	return await _part2.dump_flow_tex_report(host)
func _collect_flow_tex_report(host) -> Dictionary:
	return _part2._collect_flow_tex_report(host)
func _flow_buffer_stats(host, buffer: PackedFloat32Array, expected: int) -> Dictionary:
	return _part2._flow_buffer_stats(host, buffer, expected)
func _flow_texture_descriptor(host, texture) -> Dictionary:
	return _part2._flow_texture_descriptor(host, texture)
func _flow_format_descriptor(host, format: int) -> Dictionary:
	return _part2._flow_format_descriptor(host, format)
func _flow_sampler_inventory(host, material: ShaderMaterial) -> Array:
	return _part2._flow_sampler_inventory(host, material)
func _capture_flow_debug_view(host, view: int):
	return await _part2._capture_flow_debug_view(host, view)
func _decode_flow_texture_size_view(host, image) -> Dictionary:
	return _part2._decode_flow_texture_size_view(host, image)
func _summarize_flow_debug_image(host, image) -> Dictionary:
	return _part2._summarize_flow_debug_image(host, image)
func _print_flow_tex_report_section(host, name: String, value) -> void:
	_part2._print_flow_tex_report_section(host, name, value)
func _print_terrain_sampler_inventory(host) -> void:
	_part2._print_terrain_sampler_inventory(host)
func _print_daily_lut_upload_state(host, which: String) -> void:
	_part2._print_daily_lut_upload_state(host, which)
func _set_terrain_gi_disabled(host, disabled: bool) -> void:
	_part2._set_terrain_gi_disabled(host, disabled)
func _print_terrain_gi_state(host, tag: String) -> void:
	_part2._print_terrain_gi_state(host, tag)
func _gm_call_renderer_toggle(host, method: String, enabled: bool) -> bool:
	return _part2._gm_call_renderer_toggle(host, method, enabled)
func _gm_arg(host, name: String, type: String, required: bool) -> Dictionary:
	return _part2._gm_arg(host, name, type, required)
func _gm_choice_arg(host, name: String, choices) -> Dictionary:
	return _part2._gm_choice_arg(host, name, choices)
func _gm_positive_arg(host, name: String, type: String = "float") -> Dictionary:
	return _part2._gm_positive_arg(host, name, type)
func _gm_day_arg(host) -> Dictionary:
	return _part2._gm_day_arg(host)
func _gm_ok(host, message: String, queued: bool, effective_day: int) -> Dictionary:
	return _part2._gm_ok(host, message, queued, effective_day)
func _gm_error(host, code: String, message: String, data: Dictionary = {}) -> Dictionary:
	return _part2._gm_error(host, code, message, data)
