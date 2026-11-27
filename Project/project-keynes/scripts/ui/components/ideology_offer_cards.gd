extends RefCounted

## Builds and animates the draw tray, waiting deck, and offer candidates.


static func _rebuild_offer(owner: IdeologyWorkspace) -> void:
	if owner._offer_anim_busy:
		return
	var active := bool(owner._snapshot.get("offer_active", false))
	var generation := int(owner._snapshot.get("offer_generation", 0))
	var waiting := owner._draw_waiting()
	var chosen := active and generation == owner._chosen_generation
	var dismissed := active and generation == owner._dismissed_generation and not waiting
	if (not active and not waiting) or chosen or dismissed:
		owner._set_stage_visible(false)
		owner._set_draw_stack(false)
		for index in 3:
			owner._choice(index).visible = false
		if not active:
			owner._chosen_generation = -1
		# The stage is closed: never leave the paper cover or a face-down card
		# armed for the next reveal.
		return
	owner._set_stage_visible(true)
	var ids: PackedInt32Array = owner._snapshot.get("offer_ids", PackedInt32Array())
	var fresh := active and generation > owner._revealed_generation and not waiting
	if waiting and not fresh:
		# Draw submitted; the one-day settlement has not published yet. Showing
		# three face-down frames here is what read as a placeholder image before
		# the reveal, so only the shuffled deck is on stage.
		owner._render_draw_waiting()
		return
	owner._set_draw_stack(false)
	owner._offer_title.text = "选择国策"
	for index in 3:
		var card := owner._choice(index)
		var show := index < ids.size()
		card.visible = show
		if show:
			var ideology_id := int(ids[index])
			var meta: Dictionary = owner._metadata.get(ideology_id, {})
			var view := CountryViewModel.present_ideology_card(meta, 0)
			card.call("set_card", {
				"ideology_id": ideology_id,
				"display_name": owner._display_name(meta, ideology_id),
				"school_id": String(meta.get("school_id", "")),
				"rarity": int(meta.get("rarity", 1)),
				"rarity_label": String(meta.get("rarity_label", "")),
				"effects": view.get("effect_lines", PackedStringArray()),
				"level": 0,
				"level_count": int(view.get("level_count", 3)),
				"level_label": String(view.get("level_label", "")),
				"tooltip": String(view.get("tooltip", "")),
				"detail_model": owner._detail_data(ideology_id, true),
			})
			owner._apply_offer_card_tilt(card, index, int(meta.get("rarity", 1)))
	var reroll_cost := String(owner._presentation.get("reroll_cost_text", ""))
	owner._reroll_button.text = "重抽 · %s" % reroll_cost
	owner._reroll_button.disabled = not bool(owner._presentation.get("can_reroll", false))
	owner._reroll_button.tooltip_text = "花费 %s 理念点重抽" % reroll_cost
	owner._dismiss_button.disabled = false
	if fresh:
		owner._revealed_generation = generation
		owner._play_reveal(ids.size())
	else:
		for index in 3:
			owner._choice(index).call("set_face_up", true)



static func _render_draw_waiting(owner: IdeologyWorkspace) -> void:
	owner._offer_title.text = "正在抽取"
	owner._offer_hint.text = "正在整理候选国策…"
	for index in 3:
		var card := owner._choice(index)
		card.visible = false
		card.call("reset_motion")
	owner._reroll_button.disabled = true
	owner._dismiss_button.disabled = true
	owner._set_draw_stack(true)



static func _apply_offer_card_tilt(owner: IdeologyWorkspace, card: Control, _index: int, _rarity: int) -> void:
	card.set("stage_rest_offset", Vector2.ZERO)
	card.set("stage_rest_rotation", 0.0)



static func _set_draw_stack(owner: IdeologyWorkspace, show: bool) -> void:
	if owner._draw_stack == null:
		return
	# These are alternative views of one card-height area, never two VBox rows.
	owner._offer_cards.visible = not show
	owner._offer_actions.visible = not show
	if not show and owner._offer_hint != null:
		owner._offer_hint.text = "悬停查看详情 · 单击选定 · Esc 收起"
	if show:
		owner._draw_stack.set_card_size(owner._stage_card_size())
		if not owner._draw_stack.visible:
			owner._draw_stack.visible = true
			owner._draw_stack.play(not IdeologyWorkspace.motion_reduced())
	else:
		owner._draw_stack.stop()
		owner._draw_stack.visible = false


## The offer tray is a modal layer over the workspace: a scrim plus the centred
## paper stage. Showing it fades in; hiding is instant so the closing beat of the
## choose animation is never covered by a lingering scrim.
static func _set_stage_visible(owner: IdeologyWorkspace, show: bool) -> void:
	if owner._offer != null:
		owner._offer.visible = show
	if owner._offer_layer == null:
		return
	if not show:
		if owner._offer_layer.visible:
			owner._offer_layer.visible = false
			owner._offer_layer.modulate.a = 1.0
		return
	if owner._offer_layer.visible:
		return
	owner._offer_layer.visible = true
	if IdeologyWorkspace.motion_reduced():
		owner._offer_layer.modulate.a = 1.0
		return
	owner._offer_layer.modulate.a = 0.0
	var tween := owner._offer_layer.create_tween()
	tween.tween_property(owner._offer_layer, "modulate:a", 1.0, UITokens.ANIM_FAST)


## Fully open the unroll mask and lift the torn paper. Used whenever the stage
## is shown without a reveal, so a previous cover can never linger.
static func _play_reveal(owner: IdeologyWorkspace, count: int) -> void:
	if IdeologyWorkspace.motion_reduced() or not owner.is_visible_in_tree():
		for index in count:
			owner._choice(index).call("reset_motion")
			owner._choice(index).call("set_face_up", true)
		return
	owner._offer_anim_busy = true
	for index in count:
		var card := owner._choice(index)
		card.call("reset_motion")
		card.call("set_face_up", true)
		card.call("play_drop", index * 0.07, 16.0)
		if int(card.get("_rarity")) > 1:
			var sheen := owner.create_tween()
			sheen.tween_interval(0.30 + index * 0.07)
			sheen.tween_callback(card.call.bind("play_gloss", 1))
	var tween := owner.create_tween()
	tween.tween_interval(0.45 + maxf(0, count - 1) * 0.07)
	tween.tween_callback(owner._finish_offer_animation)



static func _finish_offer_animation(owner: IdeologyWorkspace) -> void:
	owner._offer_anim_busy = false
	for index in 3:
		if owner._choice(index).visible:
			owner._choice(index).call("set_face_up", true)
	if owner.is_visible_in_tree():
		owner._choice_0.grab_focus()
	owner._rebuild_offer()



static func _on_choice_input(owner: IdeologyWorkspace, event: InputEvent, index: int) -> void:
	# Press moves keyboard/gamepad focus onto the card; the selection itself
	# arrives through `activated` on release.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		owner._choice(index).grab_focus()



static func _on_choice_activated(owner: IdeologyWorkspace, _ideology_id: int, index: int) -> void:
	owner._choose_offer(index)



static func _on_choice_detail_requested(owner: IdeologyWorkspace, ideology_id: int) -> void:
	owner._open_detail_modal(ideology_id, true)



static func _choose_offer(owner: IdeologyWorkspace, choice_index: int) -> void:
	if owner._player_controller == null or owner._offer_anim_busy:
		return
	var generation := int(owner._snapshot.get("offer_generation", 0))
	var result: Dictionary = owner._player_controller.request_command(
		IdeologyWorkspace.PlayerControllerScript.COMMAND_IDEOLOGY_CHOOSE, {
			"offer_generation": generation,
			"choice_index": choice_index,
		})
	owner._show_result(result)
	if not bool(result.get("ok", false)):
		return
	owner._flash_hint("")
	owner._chosen_generation = generation
	owner._play_choose(choice_index)



static func _play_choose(owner: IdeologyWorkspace, choice_index: int) -> void:
	if IdeologyWorkspace.motion_reduced() or not owner.is_visible_in_tree():
		owner._rebuild_offer()
		return
	owner._offer_anim_busy = true
	for index in 3:
		if index != choice_index and owner._choice(index).visible:
			owner._choice(index).call("fold_away", 0.18)
	owner._choice(choice_index).call("stamp_punch")
	var tween := owner.create_tween()
	tween.tween_interval(0.32)
	tween.tween_property(owner._offer_layer, "modulate:a", 0.0, 0.16)
	tween.tween_callback(owner._finish_choose_animation)



static func _finish_choose_animation(owner: IdeologyWorkspace) -> void:
	owner._offer_anim_busy = false
	for index in 3:
		owner._choice(index).call("reset_motion")
	owner._rebuild_offer()
	if owner.is_visible_in_tree():
		owner._offer_button.grab_focus()
