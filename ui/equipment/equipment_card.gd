class_name EquipmentCard
extends PanelContainer

## One equipment slot, as the pilot reads it.
##
## The card is presentation only: it shows what the slot registry and the
## systems hub say, and it reports the pilot's wish. Throwing the switch is the
## console's job, through the hub's own `toggle_enabled()`.

## The pilot asked for the card's device to be switched or fired.
signal action_requested(component_id: String, action: String)

@onready var _index: Label = %Index
@onready var _name: Label = %Name
@onready var _state: Label = %State
@onready var _action: Button = %Action

## The id of the device this card shows, or "" for an empty slot.
var _component_id: String = ""
## What the card's button does: "switch", "trigger" or "none".
var _action_kind: String = "none"


## The card's title, as the pilot reads it. Public so a test can ask the card
## what it says without reaching into its labels.
func card_title() -> String:
	if not is_node_ready():
		return ""
	return _name.text


## The card's state line, the same way.
func card_state() -> String:
	if not is_node_ready():
		return ""
	return _state.text


## The card's button, as the pilot reads it.
func card_action() -> String:
	if not is_node_ready():
		return ""
	return _action.text


func _ready() -> void:
	_action.pressed.connect(_on_action_pressed)


## Fill the card from one slot's status. The status is the shape
## `EquipmentSlots.slot_status()` returns, so the card never guesses.
func configure(status: Dictionary) -> void:
	if not is_node_ready():
		return
	var index := int(status.get("index", 0))
	var key := str(status.get("key", str(index + 1)))
	_component_id = str(status.get("component_id", ""))
	_action_kind = str(status.get("action", "none"))
	_index.text = "СЛОТ %02d · [%s]" % [index + 1, key]
	if bool(status.get("empty", true)):
		_name.text = "СЛОТ ОБОРУДОВАНИЯ ПУСТ"
		_state.text = "УСТРОЙСТВО НЕ УСТАНОВЛЕНО"
		_state.add_theme_color_override("font_color", Color(0.3, 0.45, 0.48, 1))
		_action.text = "—"
		_action.disabled = true
		return
	_name.text = str(status.get("title", _component_id)).to_upper()
	_state.text = _state_text(status)
	_state.add_theme_color_override("font_color", _state_color(status))
	_action.text = _action_text(status)
	_action.disabled = not _action_available(status)


## The card's state line: what the device is doing and what it asks from the
## bus. The numbers are the device's own.
func _state_text(status: Dictionary) -> String:
	var state_name := str(status.get("state_name", ""))
	var demand := float(status.get("demand", 0.0))
	var line := state_name
	if demand > 0.0:
		line += " · %.1f кВт" % demand
	if str(status.get("action", "")) == "trigger":
		var cooldown := float(status.get("cooldown_remaining", 0.0))
		if cooldown > 0.0:
			line += " · ПЕРЕЗАРЯДКА %.0f с" % cooldown
	if not bool(status.get("enabled", false)):
		line += " · ВЫКЛ"
	return line


func _state_color(status: Dictionary) -> Color:
	if not bool(status.get("available", false)):
		return Color(1.0, 0.7, 0.3, 1.0)
	if bool(status.get("enabled", false)):
		return Color(0.46, 0.95, 0.88, 1.0)
	return Color(0.48, 0.68, 0.73, 1.0)


func _action_text(status: Dictionary) -> String:
	match _action_kind:
		"trigger":
			return "ПУСК"
		"switch":
			return "ОТКЛЮЧИТЬ" if bool(status.get("enabled", false)) else "ВКЛЮЧИТЬ"
	return "—"


## A switch can always be thrown off, and can be thrown on unless the ship
## refuses (a wrecked device, a destroyed hull, a reserve too short). A trigger
## verb is offered while the device is mounted and ready to fire.
func _action_available(status: Dictionary) -> bool:
	if not str(status.get("blocked", "")).is_empty():
		return false
	match _action_kind:
		"trigger":
			return bool(status.get("can_launch", true))
		"switch":
			if bool(status.get("enabled", false)):
				return true
			return bool(status.get("can_activate", true))
	return false


func _on_action_pressed() -> void:
	if _component_id.is_empty() or _action_kind == "none":
		return
	action_requested.emit(_component_id, _action_kind)
