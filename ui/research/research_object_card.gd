class_name ResearchObjectCard
extends PanelContainer

## Reusable card for one researched object. Presentation-only: the card never
## reads the research system and only reports a selection upwards.

signal selected(object_id: String)

var object_id: String = ""

@onready var _accent: ColorRect = %Accent
@onready var _title: Label = %Title
@onready var _identifier: Label = %Identifier
@onready var _category: Label = %Category
@onready var _badge: Label = %Badge
@onready var _status: Label = %Status
@onready var _progress: ProgressBar = %Progress


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	gui_input.connect(_on_gui_input)
	_apply_style(false)


func configure(object: ResearchObject) -> void:
	object_id = object.id
	_title.text = object.title
	_identifier.text = object.id
	_category.text = object.category
	_status.text = object.status_text()
	_progress.value = object.progress * 100.0
	_progress.visible = object.progress > 0.0
	_accent.color = _accent_color(object)
	_badge.text = _badge_text(object)
	_badge.add_theme_color_override("font_color", _badge_color(object))
	_apply_style(false)


func set_selected(is_selected: bool) -> void:
	_apply_style(is_selected)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		selected.emit(object_id)
		accept_event()
	elif event.is_action_pressed("ui_accept"):
		selected.emit(object_id)
		accept_event()


func _accent_color(object: ResearchObject) -> Color:
	if object.is_dangerous:
		return Color(1.0, 0.42, 0.34, 1.0)
	if object.is_unknown:
		return Color(1.0, 0.7, 0.3, 1.0)
	if object.is_rare:
		return Color(0.68, 0.72, 1.0, 1.0)
	if object.is_new:
		return Color(0.46, 0.95, 0.88, 1.0)
	return Color(0.3, 0.82, 0.87, 1.0)


func _badge_text(object: ResearchObject) -> String:
	if object.is_dangerous:
		return "◆ ОПАСНЫЙ"
	if object.is_unknown:
		return "◇ НЕИЗВЕСТНЫЙ"
	if object.is_rare:
		return "✦ РЕДКИЙ"
	if object.is_new:
		return "● НОВЫЙ"
	match object.state:
		ResearchObject.State.IN_PROGRESS:
			return "◉ АНАЛИЗ"
		ResearchObject.State.PAUSED:
			return "‖ ПАУЗА"
		ResearchObject.State.COMPLETED, ResearchObject.State.FULLY_STUDIED:
			return "✓ ИЗУЧЕН"
	return "○ ЗАПИСЬ"


func _badge_color(object: ResearchObject) -> Color:
	if object.is_dangerous:
		return Color(1.0, 0.45, 0.38, 1.0)
	if object.is_unknown:
		return Color(1.0, 0.7, 0.3, 1.0)
	if object.is_rare:
		return Color(0.7, 0.74, 1.0, 1.0)
	if object.is_new:
		return Color(0.46, 0.95, 0.88, 1.0)
	return Color(0.46, 0.68, 0.72, 1.0)


func _apply_style(is_selected: bool) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.014, 0.055, 0.075, 0.96 if is_selected else 0.86)
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
