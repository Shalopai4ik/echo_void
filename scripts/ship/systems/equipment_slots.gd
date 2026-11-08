extends Node
class_name EquipmentSlots

## The four equipment slots of the hull.
##
## One binding system for the whole ship, not four little ones: a slot is a
## number, a component id and a key. The device behind a slot is the device the
## hub registered under that id - the same devices the equipment panel lists
## and the same switches `ShipSystems.set_enabled()` throws - so a slot can
## never disagree with the hull about what is mounted or what is running.
##
## What a key does depends on the device it is bound to:
##
##   * a switch device (the survey scanner, the research desk) is thrown on
##     and off, through the hub's own `toggle_enabled()`;
##   * a trigger device (the decoy launcher) is fired, through its own
##     `launch()` / `activate()` verb.
##
## An empty slot says so and does nothing. A key press while a panel is open
## or while the game is paused does nothing either: the panel owns the keys
## while it is up.
##
## The slot never writes the energy budget, the power split or any device
## parameter. It throws switches and fires verbs that already existed.

## A slot key was pressed. `ok` is false for an empty slot or a refused order.
signal slot_activated(index: int, component_id: String, ok: bool)

## How many slots the hull has.
const SLOT_COUNT := 4
## The group this node joins, so the HUD and the panels find it the way they
## find the ship, the world and the scanner.
const GROUP := "equipment_slots"
## The group an open interface panel joins. A slot key belongs to the pilot
## only while no panel is up.
const MODAL_GROUP := "ui_modal"

## Which device each slot carries, in slot order. An empty id is an empty
## slot: the key is still bound to it, and the panel still shows it as empty.
@export var slot_bindings: PackedStringArray = PackedStringArray([
	"scanner", "research", "decoy_launcher", "",
])

## Whether the slot keys answer at all. The switch is there for a cutscene or
## a test that wants the ship without the keyboard.
@export var slot_input_enabled: bool = true

## The hub the slots talk to, found by walking up the tree.
var _hub: Node = null


func _ready() -> void:
	add_to_group(GROUP)
	_find_hub()


## The systems hub: the parent that answers `toggle_enabled()` and
## `equipment_status()`. Found through the tree, never through a global.
func _find_hub() -> void:
	if _hub != null and is_instance_valid(_hub):
		return
	var node := get_parent()
	while node != null:
		if node.has_method("toggle_enabled") and node.has_method("equipment_status"):
			_hub = node
			return
		node = node.get_parent()


## ------------------------------------------------------------------ reading ---

func slot_count() -> int:
	return SLOT_COUNT


func bindings() -> PackedStringArray:
	return slot_bindings


## The device id in one slot, or "" for an empty one.
func slot_component_id(index: int) -> String:
	if index < 0 or index >= slot_bindings.size():
		return ""
	return slot_bindings[index]


## The key that belongs to one slot, as the pilot sees it: "1" .. "4".
func key_label(index: int) -> String:
	return str(index + 1)


## The input action that belongs to one slot.
func slot_action_name(index: int) -> String:
	return "equipment_slot_%d" % (index + 1)


## Everything one slot says, as data. The HUD and the equipment panel read
## this, so the two can never show different things.
func slot_status(index: int) -> Dictionary:
	var out := {
		"index": index,
		"key": key_label(index),
		"component_id": "",
		"title": "",
		"state_name": "",
		"enabled": false,
		"available": false,
		"empty": true,
		"action": "none",
		"action_label": "—",
		"demand": 0.0,
		"blocked": "",
	}
	if index < 0 or index >= SLOT_COUNT:
		return out
	var id := slot_component_id(index)
	if id.is_empty():
		return out
	out["component_id"] = id
	var status := _status_of(id)
	if status.is_empty():
		out["blocked"] = "unknown"
		return out
	out["empty"] = false
	out["title"] = str(status.get("title", id))
	out["state_name"] = str(status.get("state_name", ""))
	out["enabled"] = bool(status.get("enabled", false))
	out["available"] = bool(status.get("available", false))
	out["demand"] = float(status.get("demand", 0.0))
	out["blocked"] = str(status.get("block_reason", ""))
	out["can_launch"] = bool(status.get("can_launch", true))
	out["cooldown_remaining"] = float(status.get("cooldown_remaining", 0.0))
	out["can_activate"] = bool(status.get("can_activate", true))
	out["charges"] = int(status.get("charges", -1))
	out["max_charges"] = int(status.get("max_charges", -1))
	out["active"] = bool(status.get("active", false))
	out["time_remaining"] = float(status.get("time_remaining", 0.0))
	var action := _action_of(id)
	out["action"] = action
	match action:
		"switch":
			out["action_label"] = "ПЕРЕКЛЮЧИТЬ"
		"trigger":
			out["action_label"] = "ПУСК"
	return out


## ------------------------------------------------------------------ command ---

## Throw one slot. Returns true when the device moved (a switch flipped) or
## the verb fired; false for an empty slot, an unknown device or a refusal
## from the ship itself.
func activate_slot(index: int) -> bool:
	var id := slot_component_id(index)
	if id.is_empty() or _hub == null:
		slot_activated.emit(index, id, false)
		return false
	var device := _device_of(id)
	var ok := false
	match _action_of(id):
		"switch":
			ok = bool(_hub.call("toggle_enabled", id))
		"trigger":
			ok = _fire(device)
	slot_activated.emit(index, id, ok)
	return ok


## Throw one device by its id, whatever slot it sits in. The panel's card
## button uses this, so the panel and the slot keys reach the device the same
## way.
func activate_slot_for(component_id: String) -> bool:
	for index in SLOT_COUNT:
		if slot_component_id(index) == component_id:
			return activate_slot(index)
	return false


## The slot keys. They belong to the pilot only while the world is running and
## no panel is up; a panel that is open owns the keyboard.
func _unhandled_input(event: InputEvent) -> void:
	if not slot_input_enabled:
		return
	var tree := get_tree()
	if tree == null or tree.paused:
		return
	if not tree.get_nodes_in_group(MODAL_GROUP).is_empty():
		return
	for index in SLOT_COUNT:
		if not event.is_action_pressed(slot_action_name(index)):
			continue
		activate_slot(index)
		get_viewport().set_input_as_handled()
		return


## ----------------------------------------------------------------- internals ---

## The live status of one device, or an empty dictionary when the hull does
## not carry it.
func _status_of(id: String) -> Dictionary:
	if _hub == null or not is_instance_valid(_hub):
		_find_hub()
	if _hub == null or not is_instance_valid(_hub):
		return {}
	var status: Variant = _hub.call("equipment_status", id)
	if not status is Dictionary:
		return {}
	var out := status as Dictionary
	# The component knows only about itself; the hub knows about the hull and the
	# reserve. The refusal the pilot will meet is the hub's answer, so the
	# panel shows that one.
	if _hub.has_method("activation_block_reason"):
		var reason: Variant = _hub.call("activation_block_reason", id)
		if reason is String and not (reason as String).is_empty():
			out["block_reason"] = reason
	if _hub.has_method("can_activate"):
		out["can_activate"] = bool(_hub.call("can_activate", id))
	return out


## The device node behind an id, or null.
func _device_of(id: String) -> Node:
	if _hub == null or not is_instance_valid(_hub):
		return null
	if not _hub.has_method("component"):
		return null
	var device: Variant = _hub.call("component", id)
	return device as Node if device is Node else null


## What a slot key does with this device: throw its switch, or fire it.
func _action_of(id: String) -> String:
	var device := _device_of(id)
	if device == null:
		return "none"
	if device.has_method("launch") or device.has_method("activate"):
		return "trigger"
	return "switch"


## Fire a trigger device. The launcher wants a direction and gets the hull's
## own nose; a beacon wants nothing and is simply activated.
##
## A trigger device that is not lit cannot work, so the ship lights it first -
## through the very same switch the panel uses, with the very same price the
## device already had. Nothing new is charged for the convenience.
func _fire(device: Node) -> bool:
	if device == null:
		return false
	if _hub != null and is_instance_valid(_hub) and device.has_method("set_enabled"):
		if not bool(device.get("enabled")):
			var id := str(device.call("resolved_id"))
			if not bool(_hub.call("set_enabled", id, true)):
				return false
	if device.has_method("launch"):
		return bool(device.call("launch", _hull_forward()))
	if device.has_method("activate"):
		return bool(device.call("activate"))
	return false


## The direction the hull is pointing, found by walking up to the nearest
## 2D ancestor. This file never names `ShipController`.
func _hull_forward() -> Vector2:
	var node := get_parent()
	while node != null:
		if node is Node2D:
			return Vector2.RIGHT.rotated((node as Node2D).global_rotation)
		node = node.get_parent()
	return Vector2.RIGHT


## Every slot's state, in slot order.
func slot_statuses() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for index in SLOT_COUNT:
		out.append(slot_status(index))
	return out
