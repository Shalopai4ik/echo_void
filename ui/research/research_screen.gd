extends UiViewportPolicy
class_name ResearchScreen

## Visual-only research interface. All values come from local demonstration
## snapshots. No gameplay system and no `ResearchSystem` is referenced here -
## stage 7 will map a gameplay snapshot onto these components.

signal research_requested(object_id: String)
signal research_pause_requested(object_id: String)

const OBJECT_CARD_SCENE := preload("res://scenes/ui/components/ResearchObjectCard.tscn")

@export var initial_state: int = ResearchObject.State.AVAILABLE

@onready var _safe_area: MarginContainer = %SafeArea
@onready var _state_label: Label = %State
@onready var _xp_label: Label = %XpTotal
@onready var _registry_count: Label = %RegistryCount
@onready var _object_list: VBoxContainer = %ObjectList
@onready var _empty: Label = %Empty
@onready var _panel: ResearchPanel = %Panel
@onready var _demo: Button = %DemoState

var _objects: Array[ResearchObject] = []
var _cards: Dictionary = {}
var _selected_id: String = ""
var _demo_state: int = ResearchObject.State.AVAILABLE


func _ready() -> void:
	super._ready()
	_panel.start_requested.connect(func(object_id: String) -> void: research_requested.emit(object_id))
	_panel.pause_requested.connect(func(object_id: String) -> void: research_pause_requested.emit(object_id))
	_demo.pressed.connect(_cycle_demo_state)
	get_viewport().size_changed.connect(_apply_safe_insets)
	_apply_safe_insets()
	set_demo_state(initial_state)


func set_demo_state(state: int, objects: Array[ResearchObject] = []) -> void:
	_demo_state = state
	_objects = objects if not objects.is_empty() else ResearchDemoData.objects_for_state(state)
	_cards.clear()
	for child in _object_list.get_children():
		child.queue_free()
	for object in _objects:
		var card := OBJECT_CARD_SCENE.instantiate() as ResearchObjectCard
		_object_list.add_child(card)
		card.configure(object)
		card.selected.connect(select_object)
		_cards[object.id] = card
	_empty.visible = _objects.is_empty()
	_registry_count.text = "РЕЕСТР ОБЪЕКТОВ / %02d" % _objects.size()
	_selected_id = ""
	_select_first_matching_state()
	_apply_safe_insets()


func select_object(object_id: String) -> void:
	if not _cards.has(object_id):
		return
	_selected_id = object_id
	for id in _cards:
		(_cards[id] as ResearchObjectCard).set_selected(id == object_id)
	var object := _find_object(object_id)
	if object == null:
		_panel.clear()
		return
	_panel.configure(object, true)
	_apply_state_label()


func current_object() -> ResearchObject:
	return _find_object(_selected_id)


func _select_first_matching_state() -> void:
	for object in _objects:
		if object.state == _demo_state:
			select_object(object.id)
			return
	if not _objects.is_empty():
		select_object(_objects[0].id)
	else:
		_panel.clear()


func _cycle_demo_state() -> void:
	var states := [
		ResearchObject.State.UNSTUDIED,
		ResearchObject.State.AVAILABLE,
		ResearchObject.State.IN_PROGRESS,
		ResearchObject.State.PAUSED,
		ResearchObject.State.COMPLETED,
		ResearchObject.State.FULLY_STUDIED,
	]
	var index := states.find(_demo_state)
	var next_index := (index + 1) % states.size()
	_demo_state = states[next_index]
	var object := _find_object_by_state(_demo_state)
	if object != null:
		select_object(object.id)
	_apply_state_label()


func _apply_state_label() -> void:
	var object := current_object()
	if object == null:
		_state_label.text = "○ НЕТ ОБЪЕКТОВ"
		_xp_label.text = "RESEARCH XP 0"
		return
	_state_label.text = "● " + object.status_text()
	_state_label.add_theme_color_override("font_color", _state_color(object))
	_xp_label.text = "RESEARCH XP %s" % ResearchObject.format_number(object.xp_total)


func _state_color(object: ResearchObject) -> Color:
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
	return Color(0.62, 0.7, 0.72, 1.0)


func _find_object(object_id: String) -> ResearchObject:
	for object in _objects:
		if object.id == object_id:
			return object
	return null


func _find_object_by_state(state: int) -> ResearchObject:
	for object in _objects:
		if object.state == state:
			return object
	return null


func _apply_safe_insets() -> void:
	var inset := safe_inset()
	_safe_area.add_theme_constant_override("margin_left", roundi(inset))
	_safe_area.add_theme_constant_override("margin_right", roundi(inset))
	_safe_area.add_theme_constant_override("margin_top", roundi(inset * 0.75))
	_safe_area.add_theme_constant_override("margin_bottom", roundi(inset * 0.75))
