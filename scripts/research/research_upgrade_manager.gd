extends Node
class_name ResearchUpgradeManager

## The ship's upgrade desk: spends research XP on equipment levels and writes
## the resulting values straight onto the mounted devices.
##
## This is a `Node`, mounted under `Ship/Systems` exactly like any other
## device. It finds the `ResearchSystem` by walking the tree and spends XP
## through `spend_xp()`, so it never reaches into `_xp` directly. Devices are
## found through `ShipSystems.components()` by `component_id`, so the manager
## never holds a direct reference to another component.
##
## What it does:
##   1. lists every purchasable level from `profile`;
##   2. checks `can_afford()` against the research desk's XP;
##   3. spends XP atomically via `research.spend_xp()`;
##   4. snapshots each device's base attribute on first use;
##   5. writes the upgraded value onto the device;
##   6. persists levels and base values in `to_dict()` / `from_dict()`.
##
## What it deliberately does not do: no UI, no shop screen, no XP awarding.
## A panel is its own sub-stage.

## Upgrade bought: id, new level, xp spent, xp remaining.
signal upgrade_purchased(upgrade_id: String, level: int, xp_spent: int, xp_remaining: int)
## Purchase refused. `reason` is one of: "no_research_system",
## "max_level", "insufficient_xp", "device_not_found", "wrong_device_type".
signal upgrade_refused(upgrade_id: String, reason: String)
## XP was spent through this manager. `amount` is the delta, `total` is new total.
signal xp_spent(amount: int, total: int)

## The upgrade catalogue. Every purchasable level is an entry here.
@export var profile: ResearchUpgradeProfile
## The component_id of the ResearchSystem to spend XP through. Defaults to
## "research", matching the research desk's conventional id.
@export var research_component_id: String = "research"

## The research desk instance, found in `_ready()`.
var _research: ResearchSystem = null
## Purchased level per upgrade_id. "scanner.range" -> 2 means level 2 is active.
var _levels: Dictionary = {}
## Snapshot of each upgrade's base attribute value. "scanner.range" -> 1.0.
var _base_values: Dictionary = {}

func _ready() -> void:
	_find_research()
	# Re-apply any saved levels to devices that already exist.
	if _levels.size() > 0:
		_reapply_all()


## ------------------------------------------------------------------- spending ---

## The running research XP total, or 0 when no research desk is connected.
func get_xp() -> int:
	return _research.get_xp() if _research != null else 0

## True when `upgrade_id` has a next level and the desk can pay for it.
func can_afford(upgrade_id: String) -> bool:
	var level: int = _levels.get(upgrade_id, 0)
	if not profile.has_next(upgrade_id, level):
		return false
	var cost := profile.next_cost(upgrade_id, level)
	return cost >= 0 and get_xp() >= cost

## Buy the next level of `upgrade_id`. Returns true on success. On refusal,
## emits `upgrade_refused` with a reason and spends nothing.
func purchase(upgrade_id: String) -> bool:
	if _research == null:
		upgrade_refused.emit(upgrade_id, "no_research_system")
		return false

	var level: int = _levels.get(upgrade_id, 0)
	var entry := profile.find(upgrade_id, level + 1)
	if entry == null:
		upgrade_refused.emit(upgrade_id, "max_level")
		return false

	var cost := entry.cost_xp
	if get_xp() < cost:
		upgrade_refused.emit(upgrade_id, "insufficient_xp")
		return false

	var device := _find_device(entry.device_id)
	if device == null:
		upgrade_refused.emit(upgrade_id, "device_not_found")
		return false
	if not entry.device_type.is_empty():
		var script: Script = device.get_script()
		if script == null or script.get_global_name() != entry.device_type:
			upgrade_refused.emit(upgrade_id, "wrong_device_type")
			return false

	# Spend XP atomically.
	if not _research.spend_xp(cost):
		upgrade_refused.emit(upgrade_id, "insufficient_xp")
		return false

	# Record the level, snapshot base if needed, apply.
	_levels[upgrade_id] = level + 1
	if not _base_values.has(upgrade_id):
		entry.snapshot_base(device)
		_base_values[upgrade_id] = entry.base_value
	else:
		# Restore the snapshot from our records so re-application computes
		# from the original base, not an already-upgraded device value.
		entry.base_value = _base_values.get(upgrade_id, 0.0)
		entry.base_snapshotted = true
	entry.apply_to(device)

	xp_spent.emit(cost, get_xp())
	upgrade_purchased.emit(upgrade_id, level + 1, cost, get_xp())
	return true

## The currently purchased level of `upgrade_id`, or 0 when none.
func get_level(upgrade_id: String) -> int:
	return int(_levels.get(upgrade_id, 0))

## The cost of the next level of `upgrade_id`, or -1 when at max level.
func next_cost(upgrade_id: String) -> int:
	var level: int = _levels.get(upgrade_id, 0)
	return profile.next_cost(upgrade_id, level)


## ------------------------------------------------------------------- save/load ---

## Save upgrade levels and base values. For a save file.
func to_dict() -> Dictionary:
	return {
		"levels": _levels.duplicate(true),
		"base_values": _base_values.duplicate(true),
	}

## Load state previously written by `to_dict()`. Re-applies all upgrades to
## the currently mounted devices. Returns false on a bad payload.
func from_dict(data: Dictionary) -> bool:
	if not data is Dictionary:
		return false
	var levels: Dictionary = data.get("levels", {})
	var bases: Dictionary = data.get("base_values", {})
	if levels is Dictionary:
		_levels = levels.duplicate(true)
	if bases is Dictionary:
		_base_values = bases.duplicate(true)
	if _levels.size() > 0:
		_reapply_all()
	return true

## ------------------------------------------------------------------- internals ---

func _find_research() -> void:
	var node: Node = get_parent()
	while node != null:
		if node is ResearchSystem:
			_research = node
			return
		node = node.get_parent()
	# Fallback: check siblings under ShipSystems.
	var hub := _find_hub()
	if hub != null and _research == null:
		for comp in hub.components():
			if comp is ResearchSystem:
				_research = comp
				return

func _find_hub() -> ShipSystems:
	var node: Node = get_parent()
	while node != null:
		if node.has_method("components"):
			return node as ShipSystems
		node = node.get_parent()
	return null

func _find_device(device_id: String) -> Object:
	var hub := _find_hub()
	if hub == null:
		return null
	for comp in hub.components():
		if comp != null and is_instance_valid(comp) and comp.resolved_id() == device_id:
			return comp
	return null

## Re-apply every saved upgrade level to its device, restoring base values
## from our records so multiplication/addition stacks from the original.
func _reapply_all() -> void:
	for upgrade_id in _levels.keys():
		var level: int = _levels.get(upgrade_id, 0)
		if level <= 0:
			continue
		var entry := profile.find(upgrade_id, level)
		if entry == null:
			continue
		var device := _find_device(entry.device_id)
		if device == null:
			continue
		entry.base_value = _base_values.get(upgrade_id, 0.0)
		entry.base_snapshotted = true
		entry.apply_to(device)