class_name UpgradeDeviceCard
extends PanelContainer

## One selectable device row in the upgrades panel. Presentation-only: it is fed
## an `UpgradeDevice` snapshot and reports a selection upwards. No mounted
## component and no upgrade manager is read here.

signal selected(device_id: String)

const ACCENT_READY := Color(0.46, 0.95, 0.88, 1.0)
const ACCENT_LOCKED := Color(1.0, 0.7, 0.3, 1.0)
const ACCENT_MAXED := Color(0.5, 0.66, 0.7, 1.0)
const EDGE_IDLE := Color(0.1, 0.42, 0.52, 0.58)
const EDGE_SELECTED := Color(0.36, 0.86, 0.9, 0.92)

var device_id: String = ""

@onready var _accent: ColorRect = %Accent
@onready var _icon: Label = %Icon
@onready var _title: Label = %Title
@onready var _role: Label = %Role
@onready var _level: Label = %Level
@onready var _status: Label = %Status


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	gui_input.connect(_on_gui_input)
	_apply_style(false)


func configure(device: UpgradeDevice) -> void:
	device_id = device.id
	_icon.text = device.glyph
	_title.text = device.title
	_role.text = device.role
	_level.text = device.level_text()
	_status.text = device.state_text()
	var accent := _accent_for(device)
	_accent.color = accent
	_status.add_theme_color_override("font_color", accent)
	_apply_style(false)


func set_selected(is_selected: bool) -> void:
	_apply_style(is_selected)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		selected.emit(device_id)
		accept_event()
	elif event.is_action_pressed("ui_accept"):
		selected.emit(device_id)
		accept_event()


func _accent_for(device: UpgradeDevice) -> Color:
	match device.state():
		UpgradeDevice.State.UPGRADABLE:
			return ACCENT_READY
		UpgradeDevice.State.INSUFFICIENT_XP:
			return ACCENT_LOCKED
		_:
			return ACCENT_MAXED


func _apply_style(is_selected: bool) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.014, 0.055, 0.075, 0.96 if is_selected else 0.82)
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
	style.content_margin_top = 5.0
	style.content_margin_right = 7.0
	style.content_margin_bottom = 5.0
	add_theme_stylebox_override("panel", style)