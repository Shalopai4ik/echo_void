class_name UpgradeDevice
extends RefCounted

## Presentation-only snapshot of one device the ship carries and everything that
## can be upgraded on it.
##
## A card in the list and the detail panel both read this object; neither of them
## reads a mounted `ShipComponent`. Stage 7 maps a device snapshot onto it.

enum State {
	UPGRADABLE,      ## at least one path can be paid for with the shown XP
	INSUFFICIENT_XP, ## paths remain but none of them is affordable
	MAXED,           ## every path is at its catalogue maximum
}

## `component_id` of the device, e.g. "scanner".
var id: String = ""
## Human-readable device name, e.g. "СКАНЕР ОБЗОРА".
var title: String = ""
## Secondary line: the device's own class and mounting.
var role: String = ""
## One short paragraph about what the device does.
var description: String = ""
## A single glyph drawn as the device icon. No texture asset is shipped for a
## device yet, so the icon is typographic like the rest of this interface.
var glyph: String = "◇"
## Every upgrade path of this device, in catalogue order.
var upgrades: Array[UpgradeVisual] = []


## Bought levels, summed over the paths.
func level() -> int:
	var total := 0
	for upgrade in upgrades:
		total += upgrade.level
	return total


## Levels the catalogue declares, summed over the paths.
func max_level() -> int:
	var total := 0
	for upgrade in upgrades:
		total += upgrade.max_level
	return total


func level_text() -> String:
	return "УР. %d / %d" % [level(), max_level()]


func has_affordable() -> bool:
	for upgrade in upgrades:
		if upgrade.is_available():
			return true
	return false


func is_maxed() -> bool:
	for upgrade in upgrades:
		if not upgrade.is_maxed():
			return false
	return true


## The device's summary state, derived from its paths.
func state() -> int:
	if has_affordable():
		return State.UPGRADABLE
	if is_maxed():
		return State.MAXED
	return State.INSUFFICIENT_XP


func state_text() -> String:
	match state():
		State.UPGRADABLE:
			return "ДОСТУПНО"
		State.INSUFFICIENT_XP:
			return "НЕДОСТАТОЧНО XP"
		_:
			return "МАКСИМУМ"


## The cheapest next level, or 0 when nothing is left to buy. The list card uses
## it to show what the device asks for.
func cheapest_cost() -> int:
	var best := 0
	for upgrade in upgrades:
		if upgrade.is_maxed():
			continue
		if best == 0 or upgrade.cost_xp < best:
			best = upgrade.cost_xp
	return best


## The upgrade path with this id, or null.
func find_upgrade(upgrade_id: String) -> UpgradeVisual:
	for upgrade in upgrades:
		if upgrade.id == upgrade_id:
			return upgrade
	return null