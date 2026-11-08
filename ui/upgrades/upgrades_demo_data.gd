class_name UpgradesDemoData
extends RefCounted

## The isolated preview's data: the same catalogue, with one sample level per
## path so every visual state can be reviewed without a ship.
##
## Identity, titles, descriptions and units come from
## `ui/upgrades/upgrades_presentation.gd` - the table the live snapshot also
## uses - so the preview and the flight panel cannot drift apart in wording.
## Only the sample base values, the sample levels and the price ladder are
## local: they are display data, nothing reads or spends them.
##
## The levels are chosen to show every state at once: a maxed path on the signal
## light, a path the pilot cannot afford yet on the scanner, and paths that are
## ready to buy.

const PRESENTATION := preload("res://ui/upgrades/upgrades_presentation.gd")

## XP the demonstration pilot has. Big enough to pay for a few levels, small
## enough that not every path is available.
const DEMO_XP := 340
## Price of each level, indexed by the bought level: 0 -> 50, 1 -> 100, ...
const LEVEL_COSTS := [50, 100, 200, 400]
## Levels every path in the catalogue declares.
const MAX_LEVEL := 4

## Sample numbers per path: the device's starting characteristic, the per-level
## factor the catalogue applies and the level the preview shows as already
## bought. A path missing here starts at level 0.
const SAMPLES := {
	"scanner.range": {"base": 1100.0, "multiplier": 1.25, "level": 2},
	"scanner.scan_time": {"base": 3.5, "multiplier": 0.85, "level": 3},
	"scanner.sensitivity": {"base": 1.0, "multiplier": 1.2, "level": 1},
	"signal_light.radius": {"base": 600.0, "multiplier": 1.3, "level": 0},
	"signal_light.duration": {"base": 15.0, "multiplier": 1.25, "level": 2},
	"signal_light.intensity": {"base": 1.0, "multiplier": 1.2, "level": 4},
	"decoy.lifetime": {"base": 20.0, "multiplier": 1.25, "level": 1},
	"decoy.signal": {"base": 1.2, "multiplier": 1.2, "level": 0},
	"decoy.speed": {"base": 150.0, "multiplier": 1.2, "level": 0},
	"decoy.capacity": {"base": 3.0, "add": 1.0, "level": 0, "max": 2},
	"signal_light.capacity": {"base": 4.0, "add": 1.0, "level": 1, "max": 2},
	"scanner.threat_sense": {"base": 0.0, "add": 1.0, "level": 0, "max": 1},
	"scanner.silent": {"base": 1.0, "multiplier": 0.5, "level": 0, "max": 1},
	"research.speed": {"base": 1.0, "multiplier": 0.8, "level": 1, "max": 3},
	"research.range": {"base": 1500.0, "multiplier": 1.35, "level": 0, "max": 2},
}


## The XP total the demonstration panel starts with.
static func xp_total() -> int:
	return DEMO_XP


## One `UpgradeDevice` per device the ship currently carries.
static func devices() -> Array[UpgradeDevice]:
	var out: Array[UpgradeDevice] = []
	for device_id in PRESENTATION.device_ids():
		var meta := PRESENTATION.device(device_id)
		if meta.is_empty():
			continue
		out.append(_build_device(meta))
	return out


## Build one device from its presentation entry and its paths' samples.
static func _build_device(meta: Dictionary) -> UpgradeDevice:
	var device := UpgradeDevice.new()
	device.id = str(meta.get("id", ""))
	device.title = str(meta.get("title", ""))
	device.role = str(meta.get("role", ""))
	device.description = str(meta.get("description", ""))
	device.glyph = str(meta.get("glyph", "◇"))
	for path in meta.get("paths", []):
		if path is Dictionary:
			device.upgrades.append(_build_upgrade(path))
	return device


## Build one path snapshot from its presentation entry and its sample level.
static func _build_upgrade(path: Dictionary) -> UpgradeVisual:
	var sample: Dictionary = SAMPLES.get(str(path.get("id", "")), {})
	var upgrade := UpgradeVisual.new()
	upgrade.id = str(path.get("id", ""))
	upgrade.title = str(path.get("title", ""))
	upgrade.description = str(path.get("description", ""))
	upgrade.attribute_label = str(path.get("caption", ""))
	# each path tops out where the catalogue says (one-time modules at 1)
	var top := int(sample.get("max", MAX_LEVEL))
	upgrade.level = clampi(int(sample.get("level", 0)), 0, top)
	upgrade.max_level = top
	var base := float(sample.get("base", 0.0))
	var multiplier := float(sample.get("multiplier", 1.0))
	var add := float(sample.get("add", 0.0))
	var unit := str(path.get("unit", ""))
	var decimals := int(path.get("decimals", 0))
	upgrade.current_text = UpgradeVisual.format_value(
		_value(base, multiplier, upgrade.level) + add * upgrade.level, decimals, unit)
	var next := mini(upgrade.level + 1, top)
	upgrade.next_text = UpgradeVisual.format_value(
		_value(base, multiplier, next) + add * next, decimals, unit)
	upgrade.cost_xp = 0 if upgrade.level >= top else int(LEVEL_COSTS[upgrade.level])
	return upgrade


## The path's value at `level`, computed the way `ResearchUpgrade.apply_to()`
## combines a "multiply" entry with the device's base value.
static func _value(base: float, multiplier: float, level: int) -> float:
	return base * pow(multiplier, float(level))