extends InterfaceScreen
class_name EquipmentScreen

## The equipment panel: the hull's own switches, read from the ship.
##
## Every number on it comes from the slot registry and the systems hub, and
## every button reports a wish to the console - the screen itself throws no
## switch and spends nothing. That is what makes it honest: the panel cannot
## show a device that is off as on, because it is reading the device.
##
## The panel is a modal screen: while it is up the world is paused and no
## other panel may be up with it.

## The pilot asked for a device to be switched or fired.
signal device_action(component_id: String, action: String)
## The pilot asked for the scanner screen.
signal scanner_requested
## The pilot asked for the research screen.
signal research_requested
## The pilot asked for the upgrades panel.
signal upgrades_requested

const CARD_SCENE := preload("res://scenes/ui/components/EquipmentCard.tscn")

const NOTICE_NEUTRAL := Color(0.48, 0.68, 0.73, 1.0)
const NOTICE_OK := Color(0.46, 0.95, 0.88, 1.0)
const NOTICE_LOCK := Color(1.0, 0.7, 0.3, 1.0)
const LIVE_HINT := "[ESC] ЗАКРЫТЬ · [I] ОБОРУДОВАНИЕ · [1-4] СЛОТЫ"

@onready var _safe_area: MarginContainer = %SafeArea
@onready var _load: Label = %Load
@onready var _grid: GridContainer = %Grid
@onready var _hint: Label = %Hint
@onready var _close: Button = %Close

var _cards: Array[EquipmentCard] = []
var _notice: Tween


func _ready() -> void:
	super._ready()
	_close.pressed.connect(close)
	get_viewport().size_changed.connect(_apply_safe_insets)
	_apply_safe_insets()
	_hint.text = LIVE_HINT


## Rebuild the panel from the ship. Called on open and after every change the
## ship reports, so the panel and the hull cannot disagree.
func set_equipment(slots: Array[Dictionary]) -> void:
	if not is_node_ready():
		return
	for card in _cards:
		card.queue_free()
	_cards.clear()
	for status in slots:
		var card := CARD_SCENE.instantiate() as EquipmentCard
		_grid.add_child(card)
		card.configure(status)
		card.action_requested.connect(_on_device_action)
		_cards.append(card)


## The load line: what the mounted devices ask from the bus against what the
## plant can give. Both numbers are the hub's.
func set_load(demand: float, output: float) -> void:
	if not is_node_ready():
		return
	if output <= 0.0:
		_load.text = "НАГРУЗКА —"
		return
	_load.text = "НАГРУЗКА %d%%" % roundi(clampf(demand / output, 0.0, 1.0) * 100.0)


## A short word in the footer: what the ship said about the last order.
func notify(text: String, ok: bool) -> void:
	if not is_node_ready():
		return
	if _notice != null and _notice.is_valid():
		_notice.kill()
	_hint.text = text
	_hint.add_theme_color_override("font_color", NOTICE_OK if ok else NOTICE_LOCK)
	_notice = create_tween()
	_notice.tween_interval(1.8)
	_notice.tween_callback(_end_notice)


func _end_notice() -> void:
	_hint.text = LIVE_HINT
	_hint.add_theme_color_override("font_color", NOTICE_NEUTRAL)


func _on_device_action(component_id: String, action: String) -> void:
	device_action.emit(component_id, action)


func _apply_safe_insets() -> void:
	var inset := safe_inset()
	_safe_area.add_theme_constant_override("margin_left", roundi(inset))
	_safe_area.add_theme_constant_override("margin_right", roundi(inset))
	_safe_area.add_theme_constant_override("margin_top", roundi(inset * 0.75))
	_safe_area.add_theme_constant_override("margin_bottom", roundi(inset * 0.75))
