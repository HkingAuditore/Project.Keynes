extends Control
class_name PoliticsWorkspace

signal target_cells_requested(cells: PackedInt32Array)

var _model: Dictionary = {}
var _player_controller = null
var _compact := false
var _regime: Control
var _ideology: Control
var _regime_tab: Button
var _ideology_tab: Button
var _body: Control
var _active_tab := "regime"


func _ready() -> void:
	_bind_nodes()
	if not _model.is_empty():
		_apply_model()


func _bind_nodes() -> void:
	if _body != null:
		return
	_regime = get_node_or_null("Root/Regime") as Control
	_ideology = get_node_or_null("Root/Ideology") as Control
	_body = get_node_or_null("Root") as Control
	_regime_tab = get_node_or_null("Root/TopBar/Tabs/RegimeTab") as Button
	_ideology_tab = get_node_or_null("Root/TopBar/Tabs/IdeologyTab") as Button
	if _regime_tab != null:
		_regime_tab.pressed.connect(_select_tab.bind("regime"))
	if _ideology_tab != null:
		_ideology_tab.pressed.connect(_select_tab.bind("ideology"))
	if _ideology != null and _ideology.has_signal("target_cells_requested"):
		_ideology.connect("target_cells_requested",
			func(cells: PackedInt32Array): target_cells_requested.emit(cells))


func set_player_controller(controller) -> void:
	_player_controller = controller
	_bind_nodes()
	if _regime != null and _regime.has_method("set_player_controller"):
		_regime.set_player_controller(controller)
	if _ideology != null and _ideology.has_method("set_player_controller"):
		_ideology.set_player_controller(controller)


func set_model(model: Dictionary) -> void:
	_model = model
	_bind_nodes()
	_apply_model()


func refresh_model(model: Dictionary) -> void:
	_model = model
	_bind_nodes()
	_apply_model()


func set_compact(compact: bool) -> void:
	_compact = compact
	_bind_nodes()
	if _regime != null and _regime.has_method("set_compact"):
		_regime.set_compact(compact)
	if _ideology != null and _ideology.has_method("set_compact"):
		_ideology.set_compact(compact)
	_apply_tab_state()

func select_tab(tab_id: String) -> void:
	if tab_id != "regime" and tab_id != "ideology":
		return
	_active_tab = tab_id
	_apply_tab_state()


func _apply_model() -> void:
	_bind_nodes()
	var politics: Dictionary = _model.get("politics", _model)
	if _regime != null:
		_regime.set_model(politics)
		_regime.set_compact(_compact)
	if _ideology != null:
		# IdeologyWorkspace expects the country model with a top-level `ideology`
		# key. The political view model deliberately keeps that shape intact.
		var ideology_model := politics.duplicate(true)
		for key in ["country_handle", "current_day", "country_name", "facade"]:
			if not ideology_model.has(key) and _model.has(key):
				ideology_model[key] = _model[key]
		_ideology.set_model(ideology_model)
		_ideology.set_compact(_compact)
	_apply_tab_state()


func _select_tab(tab_id: String) -> void:
	if tab_id == _active_tab:
		return
	_active_tab = tab_id
	_apply_tab_state()


func _apply_tab_state() -> void:
	if _regime != null:
		_regime.visible = _active_tab == "regime"
	if _ideology != null:
		_ideology.visible = _active_tab == "ideology"
	if _regime_tab != null:
		_regime_tab.button_pressed = _active_tab == "regime"
	if _ideology_tab != null:
		_ideology_tab.button_pressed = _active_tab == "ideology"

