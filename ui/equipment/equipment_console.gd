extends InterfaceConsole
class_name EquipmentConsole

## The flight binding for the equipment panel: the one place where a button
## press becomes a switch thrown on the real ship.
##
## The panel (`EquipmentScreen`) shows the slots; this node owns the calls:
##
##   1. it finds the ship's systems hub and the slot registry, both through
##      the tree - never through a global;
##   2. it turns a card's button into the hub's own `set_enabled()` / the
##      slot's own `activate_slot()`, so the switch, the energy price and the
##      refusal are the ship's own;
##   3. it refreshes the panel from the hub's signals, so the panel cannot
##      show a device as off while the ship has it on;
##   4. it hands the pilot over to the other panels - the scanner, the
##      research desk, the upgrades.

@onready var _equipment_screen: EquipmentScreen = $Screen

var _hub: Node = null
var _slots: EquipmentSlots = null


func _ready() -> void:
	super._ready()
	panel_id = "equipment"
	toggle_action = "toggle_equipment"
	_equipment_screen.device_action.connect(_on_device_action)
	_equipment_screen.scanner_requested.connect(func() -> void: open_panel_by_id("scanner"))
	_equipment_screen.research_requested.connect(func() -> void: open_panel_by_id("research"))
	_equipment_screen.upgrades_requested.connect(func() -> void: open_panel_by_id("upgrades"))
	_find_ship_parts()
	_connect_hub()
	refresh()


## The panel this console feeds.
func screen() -> InterfaceScreen:
	return _equipment_screen


## Rebuild the panel from the ship: the slot registry's four slots and the
## hub's own load numbers.
func refresh() -> void:
	if _equipment_screen == null:
		return
	if _slots == null:
		_find_ship_parts()
	var slots: Array[Dictionary] = []
	if _slots != null:
		slots = _slots.slot_statuses()
	var demand := 0.0
	var output := 0.0
	if _hub != null and is_instance_valid(_hub):
		demand = float(_hub.call("power_demand"))
		output = float(_hub.call("power_output"))
	_equipment_screen.set_equipment(slots)
	_equipment_screen.set_load(demand, output)


## The card's button was pressed. A switch is thrown through the hub; a
## trigger is fired through the slot, which knows the device's own verb.
func _on_device_action(component_id: String, action: String) -> void:
	if _hub == null or not is_instance_valid(_hub):
		_find_ship_parts()
	if _hub == null or not is_instance_valid(_hub):
		_equipment_screen.notify("ОТКАЗ · НЕТ СИСТЕМ КОРАБЛЯ", false)
		return
	if action == "switch":
		var moved := bool(_hub.call("toggle_enabled", component_id))
		_equipment_screen.notify(_switch_notice(component_id, moved), moved)
	elif action == "trigger":
		var fired := false
		if _slots != null:
			fired = _slots.activate_slot_for(component_id)
		_equipment_screen.notify("ПУСК · %s" % component_id.to_upper(), fired)
	refresh()


## What the ship did with the switch, in the pilot's words.
func _switch_notice(component_id: String, moved: bool) -> String:
	if not moved:
		return "ОТКАЗ · %s" % component_id.to_upper()
	var on := bool(_hub.call("is_enabled", component_id))
	return "%s · %s" % [component_id.to_upper(), "ВКЛ" if on else "ВЫКЛ"]


## The hub and the slot registry, found through the tree.
func _find_ship_parts() -> void:
	if _slots == null or not is_instance_valid(_slots):
		_slots = get_tree().get_first_node_in_group(EquipmentSlots.GROUP) as EquipmentSlots
	if _hub == null or not is_instance_valid(_hub):
		_hub = _find_hub(get_tree().get_root())


## Depth-first search for the systems hub: the node that answers
## `equipment_status()`.
func _find_hub(node: Node) -> Node:
	if node.has_method("equipment_status") and node.has_method("toggle_enabled"):
		return node
	for child in node.get_children():
		var found := _find_hub(child)
		if found != null:
			return found
	return null


## The hub's own signals: any change to a device refreshes the panel.
func _connect_hub() -> void:
	if _hub == null or not is_instance_valid(_hub):
		return
	if not _hub.has_signal("system_state_changed"):
		return
	var callable := Callable(self, "_on_ship_changed")
	if not _hub.is_connected("system_state_changed", callable):
		_hub.connect("system_state_changed", callable)


func _on_ship_changed(_component_id: String, _previous: int, _current: int) -> void:
	refresh()
