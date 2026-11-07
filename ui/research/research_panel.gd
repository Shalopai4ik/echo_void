class_name ResearchPanel
extends PanelContainer

## Reusable research panel. Shows one object's identity, its current research
## status, the analysis progress and the remaining time.
##
## Presentation-only: it is fed a prepared `ResearchObject` snapshot and never
## reads the research system. The progress bar is filled with a tween so the
## value moves smoothly instead of snapping.

signal start_requested(object_id: String)
signal pause_requested(object_id: String)

@onready var _title: Label = %Title
@onready var _type: Label = %Type
@onready var _category: Label = %Category
@onready var _description: Label = %Description
@onready var _knowledge: Label = %Knowledge
@onready var _status: Label = %Status
@onready var _remaining: Label = %Remaining
@onready var _progress: ProgressBar = %Progress
@onready var _progress_text: Label = %ProgressText
@onready var _visual: ResearchObjectVisual = %Visual
@onready var _results: ResearchResults = %Results
@onready var _action: Button = %Action
@onready var _placeholder: Label = %Placeholder

var _object_id: String = ""
var _progress_tween: Tween


func _ready() -> void:
	_action.pressed.connect(_on_action_pressed)


func configure(object: ResearchObject, animate: bool = true) -> void:
	_object_id = object.id
	_placeholder.visible = false
	_title.text = object.title
	_type.text = object.type_label
	_category.text = object.category
	_description.text = object.description
	_knowledge.text = "ИЗУЧЕННОСТЬ %s" % object.knowledge_text()
	_status.text = object.status_text()
	_status.add_theme_color_override("font_color", _status_color(object))
	_visual.kind = object.visual_kind
	_visual.accent = _visual_color(object)
	_visual.scanning = object.state == ResearchObject.State.IN_PROGRESS
	_remaining.text = _remaining_text(object)
	_apply_progress(object, animate)
	_results.configure(object, animate)
	_apply_action(object)


func clear() -> void:
	_object_id = ""
	_placeholder.visible = true
	_title.text = "ОБЪЕКТ НЕ ВЫБРАН"
	_type.text = "ТИП ОБЪЕКТА"
	_category.text = "КАТЕГОРИЯ"
	_description.text = "Выберите запись в реестре, чтобы открыть карточку и состояние исследования."
	_knowledge.text = "ИЗУЧЕННОСТЬ 0/5"
	_status.text = "НЕТ ДАННЫХ"
	_status.add_theme_color_override("font_color", Color(0.42, 0.56, 0.6, 1.0))
	_remaining.text = "ОСТАЛОСЬ --:--"
	_visual.kind = "unknown"
	_visual.scanning = false
	_apply_progress_value(0.0, false)
	_results.configure(ResearchObject.new(), false)
	_action.disabled = true
	_action.text = "НАЧАТЬ ИССЛЕДОВАНИЕ"


func _apply_progress(object: ResearchObject, animate: bool) -> void:
	var target := clampf(object.progress, 0.0, 1.0) * 100.0
	if _progress_tween != null and _progress_tween.is_valid():
		_progress_tween.kill()
	_progress_tween = null
	if not animate:
		_apply_progress_value(target, false)
		return
	_progress_tween = create_tween()
	_progress_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_progress_tween.tween_method(_apply_progress_value, _progress.value, target, 0.45)
	_progress_tween.tween_callback(_update_progress_text.bind(target))


func _apply_progress_value(value: float, _unused: Variant = null) -> void:
	_progress.value = clampf(value, 0.0, 100.0)
	_update_progress_text(_progress.value)


func _update_progress_text(value: float) -> void:
	_progress_text.text = "АНАЛИЗ %03d%%" % int(round(clampf(value, 0.0, 100.0)))


func _remaining_text(object: ResearchObject) -> String:
	match object.state:
		ResearchObject.State.IN_PROGRESS, ResearchObject.State.PAUSED:
			return "ОСТАЛОСЬ %s" % ResearchObject.format_time(object.time_remaining)
		ResearchObject.State.COMPLETED, ResearchObject.State.FULLY_STUDIED:
			return "ЗАВЕРШЕНО 00:00"
		_:
			return "ОСТАЛОСЬ --:--"


func _apply_action(object: ResearchObject) -> void:
	match object.state:
		ResearchObject.State.AVAILABLE:
			_action.disabled = false
			_action.text = "НАЧАТЬ ИССЛЕДОВАНИЕ"
		ResearchObject.State.IN_PROGRESS:
			_action.disabled = false
			_action.text = "ПРИОСТАНОВИТЬ АНАЛИЗ"
		ResearchObject.State.PAUSED:
			_action.disabled = false
			_action.text = "ПРОДОЛЖИТЬ АНАЛИЗ"
		ResearchObject.State.COMPLETED:
			_action.disabled = true
			_action.text = "АНАЛИЗ ЗАВЕРШЁН"
		ResearchObject.State.FULLY_STUDIED:
			_action.disabled = true
			_action.text = "ОБЪЕКТ ПОЛНОСТЬЮ ИЗУЧЕН"
		_:
			_action.disabled = true
			_action.text = "ИССЛЕДОВАНИЕ НЕДОСТУПНО"


func _status_color(object: ResearchObject) -> Color:
	match object.state:
		ResearchObject.State.IN_PROGRESS:
			return Color(0.46, 0.95, 0.88, 1.0)
		ResearchObject.State.PAUSED:
			return Color(1.0, 0.72, 0.32, 1.0)
		ResearchObject.State.COMPLETED:
			return Color(0.48, 0.95, 0.84, 1.0)
		ResearchObject.State.FULLY_STUDIED:
			return Color(0.5, 0.66, 0.7, 1.0)
		ResearchObject.State.AVAILABLE:
			return Color(0.36, 0.86, 0.9, 1.0)
	return Color(0.42, 0.56, 0.6, 1.0)


func _visual_color(object: ResearchObject) -> Color:
	if object.is_dangerous:
		return Color(1.0, 0.42, 0.34, 1.0)
	if object.is_unknown:
		return Color(1.0, 0.7, 0.3, 1.0)
	if object.is_rare:
		return Color(0.68, 0.72, 1.0, 1.0)
	return Color(0.36, 0.86, 0.9, 1.0)


func _on_action_pressed() -> void:
	if _object_id.is_empty():
		return
	if _action.text == "ПРИОСТАНОВИТЬ АНАЛИЗ":
		pause_requested.emit(_object_id)
	else:
		start_requested.emit(_object_id)
