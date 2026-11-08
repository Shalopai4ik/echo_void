class_name UpgradePathRow
extends PanelContainer

## One upgrade path inside the device detail: what it changes now, what it
## changes after the next level, the level count and the price. Presentation
## only - the row is fed an `UpgradeVisual` snapshot and emits a selection.

signal selected(upgrade_id: String)

const TEXT_BRIGHT := Color(0.82, 0.95, 0.98, 1.0)
const TEXT_DIM := Color(0.48, 0.68, 0.73, 1.0)
const TEXT_MUTED := Color(0.42, 0.56, 0.6, 1.0)
const ACCENT_READY := Color(0.46, 0.95, 0.88, 1.0)
const ACCENT_LOCKED := Color(1.0, 0.7, 0.3, 1.0)
const ACCENT_MAXED := Color(0.5, 0.66, 0.7, 1.0)
const EDGE_IDLE := Color(0.1, 0.42, 0.52, 0.45)
const EDGE_SELECTED := Color(0.36, 0.86, 0.9, 0.9)

var upgrade_id: String = ""

@onready var _title: Label = %Title
@onready var _level: Label = %Level
@onready var _status: Label = %Status
@onready var _change: Label = %Change
@onready var _cost: Label = %Cost


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	gui_input.connect(_on_gui_input)
	_apply_style(false)


func configure(upgrade: UpgradeVisual) -> void:
	upgrade_id = upgrade.id
	_title.text = upgrade.title
	_level.text = upgrade.level_text()
	_status.text = upgrade.status_text()
	_change.text = upgrade.change_text()
	_cost.text = upgrade.cost_text()
	var accent := _accent_for(upgrade)
	_level.add_theme_color_override("font_color", accent)
	_status.add_theme_color_override("font_color", accent)
	_change.add_theme_color_override("font_color",
		TEXT_MUTED if upgrade.is_maxed() else TEXT_BRIGHT)
	_cost.add_theme_color_override("font_color",
		ACCENT_LOCKED if upgrade.state == UpgradeVisual.State.INSUFFICIENT_XP else TEXT_DIM)
	_apply_style(false)


func set_selected(is_selected: bool) -> void:
	_apply_style(is_selected)


## Briefly brighten the row after its level was bought. Wordless confirmation
## next to the new level and price the row already shows.
func flash() -> void:
	modulate = Color(0.72, 1.0, 0.92, 1.0)
	var tween := create_tween()
	tween.tween_property(self, "modulate", Color.WHITE, 0.5)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		selected.emit(upgrade_id)
		accept_event()
	elif event.is_action_pressed("ui_accept"):
		selected.emit(upgrade_id)
		accept_event()


func _accent_for(upgrade: UpgradeVisual) -> Color:
	match upgrade.state:
		UpgradeVisual.State.AVAILABLE:
			return ACCENT_READY
		UpgradeVisual.State.INSUFFICIENT_XP:
			return ACCENT_LOCKED
		_:
			return ACCENT_MAXED


func _apply_style(is_selected: bool) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.075, 0.1, 0.9 if is_selected else 0.5)
	style.border_width_left = 2 if is_selected else 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = EDGE_SELECTED if is_selected else EDGE_IDLE
	style.corner_radius_top_left = 2
	style.corner_radius_top_right = 2
	style.corner_radius_bottom_right = 2
	style.corner_radius_bottom_left = 2
	style.content_margin_left = 7.0
	style.content_margin_top = 4.0
	style.content_margin_right = 7.0
	style.content_margin_bottom = 4.0
	add_theme_stylebox_override("panel", style)