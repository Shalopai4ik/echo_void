class_name ScannerContactCard
extends PanelContainer

## Reusable row/card for one discovered object. The card is presentation-only
## and exposes a selection signal without coupling itself to scanner logic.

signal selected(contact_id: String)

var contact_id := ""

@onready var _accent: ColorRect = %Accent
@onready var _title: Label = %Title
@onready var _type: Label = %Type
@onready var _study: Label = %Study
@onready var _distance: Label = %Distance
@onready var _badge: Label = %Badge


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	gui_input.connect(_on_gui_input)
	_apply_style(false)


func configure(contact: ScannerContact) -> void:
	contact_id = contact.id
	_title.text = contact.title
	_type.text = contact.type_label
	_study.text = "ИЗУЧЕНО " + contact.study
	_distance.text = contact.distance
	_accent.color = _accent_color(contact)
	if contact.anomaly:
		_badge.text = "◆ АНОМАЛИЯ"
		_badge.add_theme_color_override("font_color", Color(1.0, 0.42, 0.34, 1.0))
	elif contact.unknown:
		_badge.text = "◇ НЕИЗВЕСТНЫЙ СИГНАЛ"
		_badge.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3, 1.0))
	else:
		_badge.text = "ИДЕНТИФИЦИРОВАНО"
		_badge.add_theme_color_override("font_color", Color(0.46, 0.86, 0.82, 1.0))
	_apply_style(false)


func set_selected(is_selected: bool) -> void:
	_apply_style(is_selected)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		selected.emit(contact_id)
		accept_event()
	elif event.is_action_pressed("ui_accept"):
		selected.emit(contact_id)
		accept_event()


func _accent_color(contact: ScannerContact) -> Color:
	if contact.anomaly:
		return Color(1.0, 0.36, 0.28, 1.0)
	if contact.unknown:
		return Color(1.0, 0.68, 0.28, 1.0)
	match contact.marker_kind:
		"asteroid":
			return Color(0.42, 0.78, 0.82, 1.0)
		"debris":
			return Color(0.48, 0.9, 0.74, 1.0)
		"beacon":
			return Color(0.64, 0.7, 1.0, 1.0)
	return Color(0.3, 0.82, 0.87, 1.0)


func _apply_style(is_selected: bool) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.014, 0.055, 0.075, 0.96 if is_selected else 0.88)
	style.border_width_left = 2 if is_selected else 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.36, 0.86, 0.9, 0.9) if is_selected else Color(0.1, 0.42, 0.52, 0.58)
	style.corner_radius_top_left = 2
	style.corner_radius_top_right = 2
	style.corner_radius_bottom_right = 2
	style.corner_radius_bottom_left = 2
	style.content_margin_left = 8.0
	style.content_margin_top = 6.0
	style.content_margin_right = 8.0
	style.content_margin_bottom = 6.0
	add_theme_stylebox_override("panel", style)
